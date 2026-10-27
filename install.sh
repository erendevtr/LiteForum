#!/usr/bin/env bash
# =============================================================================
# LiteForum — Complete One-Shot Installer
# =============================================================================
set -Eeuo pipefail
umask 027

DOMAIN=""; ADMIN_EMAIL=""; EMAIL=""
LANG_CODE="tr"
DRY_RUN=0; SKIP_TLS=0; NO_FIREWALL=0
APP_DIR="/var/www/liteforum"; DATA_DIR="/var/lib/liteforum"; LOG_DIR="/var/log/liteforum"
SVC_USER="liteforum"; PHP_VER=""; INSTALL_LOG="/var/log/liteforum-install.log"

log()  { printf "\e[36m[%s]\e[0m %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$INSTALL_LOG"; }
ok()   { printf "\e[32m[OK]\e[0m  %s\n" "$*" | tee -a "$INSTALL_LOG"; }
warn() { printf "\e[33m[WARN]\e[0m %s\n" "$*" | tee -a "$INSTALL_LOG"; }
die()  { printf "\e[31m[FATAL]\e[0m %s\n" "$*" | tee -a "$INSTALL_LOG"; exit 1; }

usage() { cat <<EOT
LiteForum Installer
  --domain <fqdn>       Domain
  --email <mail>        Let's Encrypt + admin contact
  --admin <mail>        Admin email
  --lang <tr|en>        Install language
  --skip-tls            HTTP only
  --no-firewall         Skip UFW
  --dry-run             Plan only
  -h|--help
EOT
exit 0; }

while [[ $# -gt 0 ]]; do case "$1" in
  --domain) DOMAIN="$2"; shift 2;; --email) EMAIL="$2"; shift 2;;
  --admin) ADMIN_EMAIL="$2"; shift 2;; --lang) LANG_CODE="$2"; shift 2;;
  --skip-tls) SKIP_TLS=1; shift;; --no-firewall) NO_FIREWALL=1; shift;;
  --dry-run) DRY_RUN=1; shift;; -h|--help) usage;;
  *) die "Unknown arg: $1";;
esac; done

[[ "$LANG_CODE" == "tr" || "$LANG_CODE" == "en" ]] || die "--lang must be tr|en"
[[ $EUID -eq 0 ]] || die "root required"
[[ -n "$DOMAIN" ]] || die "--domain required"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"; EMAIL="${EMAIL:-$ADMIN_EMAIL}"

preflight() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -qq
    apt-get install -y -qq sqlite3 || die "sqlite3 install failed"
  fi
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 missing"
  ok "sqlite3 available"
}

detect_os() {
  . /etc/os-release
  case "$ID" in ubuntu|debian) ;; *) die "Only Ubuntu/Debian supported. Found: $ID";; esac
  ok "OS=$PRETTY_NAME"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq || die "apt update failed"
  apt-get upgrade -y -qq || warn "upgrade issues (continuing)"

  PHP_VER="$(apt-cache search --names-only '^php[0-9]+\.[0-9]+-fpm$' | sort -V | tail -1 | awk -F- '{print $1}')"
  [[ -n "$PHP_VER" ]] || PHP_VER="php8.2"
  ok "PHP: $PHP_VER"

  if ! apt-get install -y -qq \
      nginx nginx-common \
      "$PHP_VER-fpm" "$PHP_VER-cli" "$PHP_VER-sqlite3" "$PHP_VER-curl" \
      "$PHP_VER-mbstring" "$PHP_VER-xml" "$PHP_VER-intl" "$PHP_VER-opcache" \
      "$PHP_VER-bcmath" "$PHP_VER-gd" \
      sqlite3 curl ca-certificates openssl \
      ufw fail2ban unattended-upgrades \
      certbot python3-certbot-nginx \
      logrotate rsync jq; then
    die "Package install failed"
  fi

  apt-get install -y -qq libnginx-mod-http-headers-more-filter libnginx-mod-http-limit-req 2>/dev/null || true

  command -v nginx   >/dev/null || die "nginx binary missing"
  [[ -f /etc/nginx/nginx.conf ]] || die "/etc/nginx/nginx.conf missing"
  command -v sqlite3 >/dev/null || die "sqlite3 missing"
  command -v php     >/dev/null || die "php missing"

  install -d -o root -g root -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
  ok "Packages installed"
}

create_user() {
  id "$SVC_USER" &>/dev/null || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin --user-group "$SVC_USER"
  usermod -aG www-data "$SVC_USER" || true
  ok "Service user: $SVC_USER"
}

create_dirs() {
  install -d -o root      -g root      -m 0755 "$APP_DIR" "$APP_DIR"/{public,app,config,lang,views,plugins}
  install -d -o root      -g root      -m 0755 "$APP_DIR/public/oauth/erendev"
  install -d -o $SVC_USER -g $SVC_USER -m 0700 "$DATA_DIR" "$DATA_DIR"/{sessions,tmp,backups,uploads}
  install -d -o root      -g adm       -m 0750 "$LOG_DIR"
}

gen_secrets() {
  APP_KEY="$(openssl rand -hex 32)"
  ADMIN_PASS="$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-24)"
  OAuth_CLIENT_ID="ed_app_$(openssl rand -hex 8)"
  OAuth_CLIENT_SECRET="eds_$(openssl rand -hex 24)"
  ok "Secrets generated"
}

init_sqlite() {
  DB="$DATA_DIR/liteforum.db"
  [[ -f "$DB" ]] && { warn "DB exists, leaving untouched"; return; }
  sqlite3 "$DB" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA synchronous=NORMAL;
PRAGMA foreign_keys=ON;
PRAGMA temp_store=MEMORY;

CREATE TABLE users(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL UNIQUE,
  email TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member' CHECK(role IN ('member','moderator','admin')),
  erendev_sub TEXT UNIQUE,
  theme TEXT NOT NULL DEFAULT 'dark' CHECK(theme IN ('dark','light','high-contrast')),
  accent TEXT NOT NULL DEFAULT 'indigo' CHECK(accent IN ('indigo','emerald','rose','amber','sky')),
  notify_mentions INTEGER NOT NULL DEFAULT 1,
  notify_replies INTEGER NOT NULL DEFAULT 1,
  notify_digest INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  last_login_at INTEGER
);
CREATE TABLE categories(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  slug TEXT NOT NULL UNIQUE,
  name_tr TEXT NOT NULL, name_en TEXT NOT NULL,
  name_fr TEXT, name_de TEXT, name_es TEXT, name_ar TEXT,
  position INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE topics(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES users(id),
  title TEXT NOT NULL, slug TEXT NOT NULL,
  is_pinned INTEGER NOT NULL DEFAULT 0,
  is_locked INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE TABLE posts(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES users(id),
  body TEXT NOT NULL,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE INDEX idx_topics_cat ON topics(category_id, updated_at DESC);
CREATE INDEX idx_posts_topic ON posts(topic_id, created_at ASC);

CREATE TABLE rate_limits(id INTEGER PRIMARY KEY AUTOINCREMENT, bucket TEXT NOT NULL, ip TEXT NOT NULL, ts INTEGER NOT NULL);
CREATE INDEX idx_rate ON rate_limits(bucket, ip, ts);

CREATE TABLE notifications(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  topic_id INTEGER REFERENCES topics(id) ON DELETE CASCADE,
  post_id INTEGER REFERENCES posts(id) ON DELETE CASCADE,
  actor_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
  snippet TEXT, read_at INTEGER, created_at INTEGER NOT NULL
);
CREATE INDEX idx_notif_user ON notifications(user_id, read_at, created_at DESC);

CREATE TABLE topic_watches(
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY(user_id, topic_id)
);
CREATE TABLE audit_log(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  actor_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
  action TEXT NOT NULL, target_kind TEXT, target_id INTEGER,
  meta TEXT, ip TEXT, ts INTEGER NOT NULL
);

CREATE VIRTUAL TABLE posts_fts USING fts5(body, content='posts', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE TRIGGER posts_ai AFTER INSERT ON posts BEGIN
  INSERT INTO posts_fts(rowid,body) VALUES (new.id,new.body);
END;
CREATE TRIGGER posts_au AFTER UPDATE ON posts BEGIN
  INSERT INTO posts_fts(posts_fts,rowid,body) VALUES('delete',old.id,old.body);
  INSERT INTO posts_fts(rowid,body) VALUES (new.id,new.body);
END;
CREATE TRIGGER posts_ad AFTER DELETE ON posts BEGIN
  INSERT INTO posts_fts(posts_fts,rowid,body) VALUES('delete',old.id,old.body);
END;
SQL
  chown "$SVC_USER:$SVC_USER" "$DB"* 2>/dev/null; chmod 0600 "$DB"* 2>/dev/null
  ok "SQLite: $DB"
}

write_env() {
  cat > "$APP_DIR/config/config.php" <<PHP
<?php
return [
    'app_name'        => 'LiteForum',
    'default_lang'    => '$LANG_CODE',
    'available_langs' => ['tr','en','fr','de','es','ar'],
    'app_key'         => '$APP_KEY',
    'db_path'         => '$DATA_DIR/liteforum.db',
    'base_url'        => 'https://$DOMAIN',
    'session_name'    => 'LF_SESSION',
    'session_lifetime'=> 7200,
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
    'rate_limit' => ['login_per_10min'=>8, 'post_per_min'=>6, 'register_per_hr'=>5],
    'themes'  => ['dark','light','high-contrast'],
    'accents' => ['indigo','emerald','rose','amber','sky'],
    'admin_email' => '$ADMIN_EMAIL',
];
PHP
  chown "$SVC_USER:$SVC_USER" "$APP_DIR/config/config.php"
  chmod 0640 "$APP_DIR/config/config.php"
  ok "config.php"
}

write_i18n() {
  cat > "$APP_DIR/lang/tr.php" <<'PHP'
<?php return [
  'forum'=>'Forum','login'=>'Giriş Yap','register'=>'Kayıt Ol','logout'=>'Çıkış Yap',
  'username'=>'Kullanıcı adı','email'=>'E-posta','password'=>'Şifre',
  'categories'=>'Kategoriler','topics'=>'Konular','posts'=>'Mesajlar',
  'new_topic'=>'Yeni Konu','reply'=>'Yanıtla','search'=>'Ara...','submit'=>'Gönder',
  'notifications'=>'Bildirimler','mark_all_read'=>'Tümünü okundu işaretle','no_notifications'=>'Bildirim yok',
  'watch_topic'=>'Konuyu takip et','unwatch_topic'=>'Takibi bırak',
  'theme'=>'Tema','accent'=>'Vurgu rengi','settings'=>'Ayarlar','save'=>'Kaydet',
  'search_results'=>'Arama sonuçları','no_results'=>'Sonuç yok','search_placeholder'=>'Ara...',
  'erendev_login'=>'ErenDev ile Giriş Yap',
  'too_many_attempts'=>'Çok fazla deneme.','missing_info'=>'Eksik bilgi.',
  'bad_credentials'=>'E-posta veya şifre hatalı.','bot_detected'=>'Bot tespit edildi.',
  'register_limit'=>'Kayıt limiti aşıldı.','bad_username'=>'Kullanıcı adı 3-32 karakter olmalı.',
  'bad_email'=>'Geçerli e-posta girin.','weak_password'=>'Şifre en az 10 karakter.',
  'already_exists'=>'Zaten kayıtlı.',
];
PHP
  cat > "$APP_DIR/lang/en.php" <<'PHP'
<?php return [
  'forum'=>'Forum','login'=>'Log in','register'=>'Sign up','logout'=>'Log out',
  'username'=>'Username','email'=>'Email','password'=>'Password',
  'categories'=>'Categories','topics'=>'Topics','posts'=>'Posts',
  'new_topic'=>'New topic','reply'=>'Reply','search'=>'Search...','submit'=>'Submit',
  'notifications'=>'Notifications','mark_all_read'=>'Mark all as read','no_notifications'=>'No notifications',
  'watch_topic'=>'Watch topic','unwatch_topic'=>'Unwatch',
  'theme'=>'Theme','accent'=>'Accent color','settings'=>'Settings','save'=>'Save',
  'search_results'=>'Search results','no_results'=>'No results','search_placeholder'=>'Search...',
  'erendev_login'=>'Sign in with ErenDev',
  'too_many_attempts'=>'Too many attempts.','missing_info'=>'Missing information.',
  'bad_credentials'=>'Incorrect email or password.','bot_detected'=>'Bot detected.',
  'register_limit'=>'Registration limit exceeded.','bad_username'=>'Username must be 3-32 chars.',
  'bad_email'=>'Enter a valid email.','weak_password'=>'Password min 10 chars.',
  'already_exists'=>'Already registered.',
];
PHP
  for lc in fr de es ar; do
    cp "$APP_DIR/lang/en.php" "$APP_DIR/lang/$lc.php"
  done
  chown -R root:root "$APP_DIR/lang"; chmod 0644 "$APP_DIR/lang"/*.php
  ok "i18n"
}

write_app() {
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
require LF_ROOT . '/app/notifications.php';
require LF_ROOT . '/app/search.php';
require LF_ROOT . '/app/theme.php';

session_name($config['session_name']);
session_set_cookie_params([
  'lifetime'=>0,'path'=>'/',
  'secure'=>!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS']==='on',
  'httponly'=>true,'samesite'=>'Strict',
]);
session_start();

if (!isset($_SESSION['ui_lang']) || !in_array($_SESSION['ui_lang'], $config['available_langs'], true)) {
  $_SESSION['ui_lang'] = $config['default_lang'];
}
i18n_init($_SESSION['ui_lang']);
csrf_init($config['app_key']);
$db = db_init($config['db_path']);
$GLOBALS['__config'] = $config;
$GLOBALS['__config_available_langs'] = $config['available_langs'] ?? ['tr','en'];
PHP

  cat > "$APP_DIR/app/db.php" <<'PHP'
<?php
declare(strict_types=1);
function db_init(string $path): PDO {
  static $pdo=null; if ($pdo) return $pdo;
  $pdo = new PDO('sqlite:'.$path, null, null, [
    PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC,
    PDO::ATTR_EMULATE_PREPARES=>false,
  ]);
  foreach (['journal_mode=WAL','busy_timeout=5000','synchronous=NORMAL','foreign_keys=ON','temp_store=MEMORY'] as $p)
    $pdo->exec("PRAGMA $p;");
  return $pdo;
}
PHP

  cat > "$APP_DIR/app/helpers.php" <<'PHP'
<?php
declare(strict_types=1);
function e(?string $s): string { return htmlspecialchars((string)$s, ENT_QUOTES|ENT_SUBSTITUTE, 'UTF-8'); }
function csp_nonce(): string { static $n=null; if ($n===null) $n=base64_encode(random_bytes(16)); return $n; }
function redirect(string $to): never { header('Location: '.$to, true, 302); exit; }
function rate_limit(PDO $db, string $bucket, string $ip, int $max, int $w): bool {
  $now=time(); $db->prepare('DELETE FROM rate_limits WHERE ts<?')->execute([$now-$w]);
  $st=$db->prepare('SELECT COUNT(*) FROM rate_limits WHERE bucket=? AND ip=? AND ts>=?');
  $st->execute([$bucket,$ip,$now-$w]);
  if ((int)$st->fetchColumn()>=$max) return false;
  $db->prepare('INSERT INTO rate_limits(bucket,ip,ts) VALUES(?,?,?)')->execute([$bucket,$ip,$now]);
  return true;
}
function client_ip(): string { return $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0'; }
function audit(PDO $db, ?array $actor, string $action, ?string $kind=null, ?int $id=null, array $meta=[]): void {
  $db->prepare('INSERT INTO audit_log(actor_id,action,target_kind,target_id,meta,ip,ts) VALUES(?,?,?,?,?,?,?)')
     ->execute([$actor['id']??null, $action, $kind, $id, json_encode($meta), client_ip(), time()]);
}
PHP

  cat > "$APP_DIR/app/csrf.php" <<'PHP'
<?php
declare(strict_types=1);
function csrf_init(string $k): void { $_SESSION['csrf_token'] ??= bin2hex(random_bytes(32)); $_SESSION['csrf_key'] ??= $k; }
function csrf_token(): string { return $_SESSION['csrf_token']; }
function csrf_field(): string { return '<input type="hidden" name="_csrf" value="'.e(csrf_token()).'">'; }
function csrf_verify(): void {
  $t=$_POST['_csrf']??'';
  if (!is_string($t) || !hash_equals($_SESSION['csrf_token']??'', $t)) { http_response_code(419); exit('Invalid CSRF token.'); }
}
PHP

  cat > "$APP_DIR/app/auth.php" <<'PHP'
<?php
declare(strict_types=1);
function auth_user(): ?array { return $_SESSION['user'] ?? null; }
function auth_require(): array { $u=auth_user(); if (!$u) redirect('/login.php'); return $u; }
function auth_admin(): array { $u=auth_require(); if ($u['role']!=='admin') { http_response_code(403); exit('Forbidden'); } return $u; }
function auth_login(array $u): void {
  session_regenerate_id(true);
  $_SESSION['user']=['id'=>(int)$u['id'],'username'=>$u['username'],'role'=>$u['role']];
  $GLOBALS['db']->prepare('UPDATE users SET last_login_at=? WHERE id=?')->execute([time(),(int)$u['id']]);
}
function auth_logout(): void {
  $_SESSION=[];
  if (ini_get('session.use_cookies')) {
    $p=session_get_cookie_params();
    setcookie(session_name(),'',time()-42000,$p['path'],$p['domain'],$p['secure'],$p['httponly']);
  }
  session_destroy();
}
function password_hash_safe(string $p): string { return password_hash($p, PASSWORD_ARGON2ID); }
function password_verify_safe(string $p, string $h): bool { return password_verify($p, $h); }
PHP

  cat > "$APP_DIR/app/i18n.php" <<'PHP'
<?php
declare(strict_types=1);
$GLOBALS['__lang'] = [];
function i18n_init(string $code): void {
  $cfg = $GLOBALS['__config_available_langs'] ?? ['tr','en','fr','de','es','ar'];
  $code = in_array($code, $cfg, true) ? $code : 'en';
  $path = LF_ROOT.'/lang/'.$code.'.php';
  $GLOBALS['__lang'] = is_file($path) ? require $path : require LF_ROOT.'/lang/en.php';
}
function t(string $k): string { return $GLOBALS['__lang'][$k] ?? $k; }
PHP

  cat > "$APP_DIR/app/theme.php" <<'PHP'
<?php
declare(strict_types=1);
function theme_css_vars(): string {
  $u = $_SESSION['user'] ?? null;
  $theme  = $u['theme']  ?? 'dark';
  $accent = $u['accent'] ?? 'indigo';
  $map = [
    'indigo'  => ['500'=>'#6366f1','600'=>'#4f46e5','400'=>'#818cf8'],
    'emerald' => ['500'=>'#10b981','600'=>'#059669','400'=>'#34d399'],
    'rose'    => ['500'=>'#f43f5e','600'=>'#e11d48','400'=>'#fb7185'],
    'amber'   => ['500'=>'#f59e0b','600'=>'#d97706','400'=>'#fbbf24'],
    'sky'     => ['500'=>'#0ea5e9','600'=>'#0284c7','400'=>'#38bdf8'],
  ];
  $c = $map[$accent] ?? $map['indigo'];
  if ($theme === 'light') {
    return "--bg:#f8fafc;--fg:#0f172a;--panel:#ffffff;--border:#e2e8f0;--accent-500:{$c['500']};--accent-600:{$c['600']};--accent-400:{$c['400']};color-scheme:light;";
  }
  if ($theme === 'high-contrast') {
    return "--bg:#000000;--fg:#ffffff;--panel:#0a0a0a;--border:#404040;--accent-500:#ffff00;--accent-600:#ffff00;--accent-400:#ffff00;color-scheme:dark;";
  }
  return "--bg:#020617;--fg:#cbd5e1;--panel:rgba(15,23,42,.6);--border:#1e293b;--accent-500:{$c['500']};--accent-600:{$c['600']};--accent-400:{$c['400']};color-scheme:dark;";
}
PHP

  cat > "$APP_DIR/app/notifications.php" <<'PHP'
<?php
declare(strict_types=1);
function notif_create(PDO $db, int $userId, string $kind, ?int $topicId, ?int $postId, ?int $actorId, string $snippet): void {
  if ($userId === $actorId) return;
  $db->prepare('INSERT INTO notifications(user_id,kind,topic_id,post_id,actor_id,snippet,created_at) VALUES(?,?,?,?,?,?,?)')
     ->execute([$userId,$kind,$topicId,$postId,$actorId,mb_substr($snippet,0,140),time()]);
}
function notif_for_mentions(PDO $db, string $body, int $topicId, int $postId, int $actorId): void {
  if (!preg_match_all('/@([A-Za-z0-9_\-]{3,32})/', $body, $m)) return;
  $st = $db->prepare('SELECT id FROM users WHERE username = ?');
  foreach (array_unique($m[1]) as $uname) {
    $st->execute([$uname]);
    if ($uid = $st->fetchColumn()) notif_create($db, (int)$uid, 'mention', $topicId, $postId, $actorId, $body);
  }
}
function notif_for_replies(PDO $db, int $topicId, int $postId, int $actorId, string $body): void {
  $st = $db->prepare('SELECT user_id FROM topic_watches WHERE topic_id = ? AND user_id != ?');
  $st->execute([$topicId, $actorId]);
  foreach ($st->fetchAll(PDO::FETCH_COLUMN) as $uid) notif_create($db, (int)$uid, 'reply', $topicId, $postId, $actorId, $body);
}
function notif_unread_count(PDO $db, int $userId): int {
  $st = $db->prepare('SELECT COUNT(*) FROM notifications WHERE user_id=? AND read_at IS NULL');
  $st->execute([$userId]); return (int)$st->fetchColumn();
}
function notif_list(PDO $db, int $userId, int $limit=50): array {
  $st = $db->prepare('SELECT n.*, u.username AS actor FROM notifications n LEFT JOIN users u ON u.id=n.actor_id WHERE n.user_id=? ORDER BY n.created_at DESC LIMIT ?');
  $st->execute([$userId,$limit]); return $st->fetchAll();
}
function notif_mark_all_read(PDO $db, int $userId): void {
  $db->prepare('UPDATE notifications SET read_at=? WHERE user_id=? AND read_at IS NULL')->execute([time(),$userId]);
}
PHP

  cat > "$APP_DIR/app/search.php" <<'PHP'
<?php
declare(strict_types=1);
function search_posts(PDO $db, string $q, ?int $categoryId=null, ?int $authorId=null, int $page=1, int $per=20): array {
  $q = trim($q);
  if ($q === '') return ['rows'=>[], 'total'=>0];
  $sql = 'SELECT p.id, p.topic_id, p.user_id, p.created_at,
                 snippet(posts_fts, 0, \'<mark>\', \'</mark>\', \'…\', 20) AS snippet,
                 bm25(posts_fts) AS rank,
                 t.title AS topic_title, t.category_id, u.username
          FROM posts_fts
          JOIN posts p ON p.id = posts_fts.rowid
          JOIN topics t ON t.id = p.topic_id
          JOIN users u ON u.id = p.user_id
          WHERE posts_fts MATCH ?';
  $params = [$q];
  if ($categoryId) { $sql .= ' AND t.category_id = ?'; $params[] = $categoryId; }
  if ($authorId)   { $sql .= ' AND p.user_id = ?'; $params[] = $authorId; }
  $sql .= ' ORDER BY rank LIMIT ? OFFSET ?';
  $params[] = $per; $params[] = max(0, ($page-1)*$per);
  $st = $db->prepare($sql);
  try { $st->execute($params); } catch (PDOException $e) { return ['rows'=>[], 'total'=>0]; }
  return ['rows'=>$st->fetchAll(), 'total'=>count($st->fetchAll())];
}
PHP
  chown -R root:root "$APP_DIR/app"; chmod -R 0755 "$APP_DIR/app"
  ok "app/"
}

write_views() {
  cat > "$APP_DIR/views/layout.php" <<'PHP'
<?php /* @var string $content @var string $title */ $u = auth_user(); ?>
<!doctype html>
<html lang="<?= e($_SESSION['ui_lang'] ?? 'tr') ?>" dir="<?= ($_SESSION['ui_lang'] ?? 'tr')==='ar'?'rtl':'ltr' ?>">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= e($title ?? 'LiteForum') ?> · LiteForum</title>
<style nonce="<?= e(csp_nonce()) ?>">
  :root { <?= theme_css_vars() ?> }
  body{background:var(--bg);color:var(--fg);font-family:ui-sans-serif,system-ui,-apple-system,sans-serif;margin:0;min-height:100vh}
  a{color:var(--accent-400);text-decoration:none}a:hover{text-decoration:underline}
  .container{max-width:1100px;margin:0 auto;padding:2rem 1.25rem}
  .glass{background:var(--panel);backdrop-filter:blur(8px);border:1px solid var(--border);border-radius:1rem;box-shadow:0 25px 50px -12px rgba(0,0,0,.6)}
  header.nav{position:sticky;top:0;z-index:10;border-bottom:1px solid var(--border);background:var(--panel);backdrop-filter:blur(8px)}
  header.nav .inner{max-width:1100px;margin:0 auto;padding:1rem 1.25rem;display:flex;justify-content:space-between;align-items:center;gap:.75rem;flex-wrap:wrap}
  .logo{display:flex;gap:.5rem;align-items:center;color:var(--fg);font-weight:600}
  .logo .mark{width:32px;height:32px;border-radius:.5rem;background:var(--accent-500);display:flex;align-items:center;justify-content:center;font-weight:700;color:#fff}
  input,textarea,select{background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:.5rem;padding:.55rem .75rem;width:100%;box-sizing:border-box;font:inherit}
  button,.btn{background:var(--accent-500);color:#fff;border:0;border-radius:.5rem;padding:.6rem 1rem;cursor:pointer;font-weight:600}
  button:hover,.btn:hover{background:var(--accent-600)}
  .btn-ghost{background:transparent;border:1px solid var(--border);color:var(--fg)}
  .muted{color:#94a3b8}.card{padding:1.5rem}.flex{display:flex;gap:.75rem;align-items:center}.grid{display:grid;gap:1rem}
  table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:.75rem 1rem;border-bottom:1px solid var(--border)}
  .badge-notif{display:inline-block;background:#ef4444;color:#fff;border-radius:999px;font-size:11px;padding:1px 6px;margin-left:4px}
  mark{background:var(--accent-500);color:#fff;padding:0 2px;border-radius:2px}
</style>
</head>
<body>
<header class="nav"><div class="inner">
  <a class="logo" href="/"><span class="mark">L</span><span>LiteForum</span></a>
  <nav class="flex" style="flex-wrap:wrap">
    <form action="/search.php" method="get" style="margin:0" class="flex">
      <input name="q" placeholder="<?= e(t('search_placeholder')) ?>" style="width:180px;padding:.35rem .5rem;font-size:13px">
    </form>
    <form method="post" action="/lang.php" style="margin:0" class="flex">
      <?= csrf_field() ?>
      <select name="lang" onchange="this.form.submit()" style="width:auto;padding:.35rem .5rem;font-size:12px">
        <?php foreach (($GLOBALS['__config']['available_langs'] ?? ['tr','en']) as $lc): ?>
          <option value="<?= e($lc) ?>" <?= ($_SESSION['ui_lang']??'')===$lc?'selected':'' ?>><?= e(strtoupper($lc)) ?></option>
        <?php endforeach; ?>
      </select>
    </form>
    <?php if ($u): ?>
      <a href="/notifications.php" style="position:relative">🔔<?php $n=notif_unread_count($GLOBALS['db'],(int)$u['id']); if ($n>0): ?><span class="badge-notif"><?= $n ?></span><?php endif; ?></a>
      <a href="/settings.php">⚙</a>
      <span class="muted">@<?= e($u['username']) ?></span>
      <?php if ($u['role']==='admin'): ?><a href="/admin.php">Admin</a><?php endif; ?>
      <form method="post" action="/logout.php" style="margin:0"><?= csrf_field() ?><button class="btn-ghost" type="submit"><?= e(t('logout')) ?></button></form>
    <?php else: ?>
      <a href="/login.php"><?= e(t('login')) ?></a>
      <a href="/register.php"><?= e(t('register')) ?></a>
    <?php endif; ?>
  </nav>
</div></header>
<main class="container"><?= $content ?></main>
</body></html>
PHP

  cat > "$APP_DIR/views/home.php" <<'PHP'
<?php /* @var array $cats */ $lc = $_SESSION['ui_lang'] ?? 'tr'; ?>
<div class="glass card">
  <h1 style="margin:0 0 1rem;color:var(--fg)"><?= e(t('forum')) ?></h1>
  <table><thead><tr><th><?= e(t('categories')) ?></th><th><?= e(t('topics')) ?></th></tr></thead><tbody>
    <?php foreach ($cats as $c): ?>
      <tr><td><a href="/category.php?slug=<?= e($c['slug']) ?>"><?= e($c['name_'.$lc] ?? $c['name_en']) ?></a></td>
          <td class="muted"><?= (int)$c['n'] ?></td></tr>
    <?php endforeach; ?>
  </tbody></table>
</div>
PHP

  cat > "$APP_DIR/views/category.php" <<'PHP'
<?php /* @var array $cat @var array $topics */ $lc = $_SESSION['ui_lang'] ?? 'tr'; ?>
<div class="glass card">
  <h1 style="margin:0 0 1rem;color:var(--fg)"><?= e($cat['name_'.$lc] ?? $cat['name_en']) ?></h1>
  <p><a href="/new-topic.php?cat=<?= (int)$cat['id'] ?>">+ <?= e(t('new_topic')) ?></a></p>
  <?php if (empty($topics)): ?>
    <p class="muted">Henüz konu yok.</p>
  <?php else: ?>
    <table><thead><tr><th>Konu</th><th>Yazar</th><th>Mesaj</th><th>Tarih</th></tr></thead><tbody>
      <?php foreach ($topics as $t): ?>
        <tr>
          <td><?php if ((int)$t['is_pinned']): ?>📌 <?php endif; ?><a href="/topic.php?id=<?= (int)$t['id'] ?>"><?= e($t['title']) ?></a></td>
          <td class="muted">@<?= e($t['username']) ?></td>
          <td class="muted"><?= (int)$t['post_count'] ?></td>
          <td class="muted"><?= date('Y-m-d', (int)$t['updated_at']) ?></td>
        </tr>
      <?php endforeach; ?>
    </tbody></table>
  <?php endif; ?>
</div>
PHP

  cat > "$APP_DIR/views/topic.php" <<'PHP'
<?php /* @var array $topic @var array $posts @var bool $watching */ ?>
<div class="glass card" style="margin-bottom:1rem">
  <h1 style="margin:0 0 .5rem;color:var(--fg)"><?= e($topic['title']) ?></h1>
  <p class="muted" style="margin:0;font-size:13px">@<?= e($topic['username']) ?> · <?= date('Y-m-d H:i', (int)$topic['created_at']) ?></p>
  <?php if (auth_user()): ?>
    <form method="post" action="/topic.php?id=<?= (int)$topic['id'] ?>" style="margin-top:.75rem">
      <?= csrf_field() ?><input type="hidden" name="action" value="toggle_watch">
      <button class="btn-ghost" type="submit"><?= e($watching ? t('unwatch_topic') : t('watch_topic')) ?></button>
    </form>
  <?php endif; ?>
</div>
<?php foreach ($posts as $p): ?>
  <div class="glass card" style="margin-bottom:.75rem">
    <p class="muted" style="margin:0 0 .5rem;font-size:12px">@<?= e($p['username']) ?> · <?= date('Y-m-d H:i', (int)$p['created_at']) ?></p>
    <div style="white-space:pre-wrap"><?= e($p['body']) ?></div>
  </div>
<?php endforeach; ?>
<?php if (auth_user() && empty($topic['is_locked'])): ?>
<div class="glass card">
  <h2 style="margin:0 0 .75rem;color:var(--fg)"><?= e(t('reply')) ?></h2>
  <form method="post" action="/topic.php?id=<?= (int)$topic['id'] ?>" class="grid">
    <?= csrf_field() ?><input type="hidden" name="action" value="reply">
    <textarea name="body" rows="5" required></textarea>
    <button type="submit"><?= e(t('submit')) ?></button>
  </form>
</div>
<?php endif; ?>
PHP

  cat > "$APP_DIR/views/new-topic.php" <<'PHP'
<?php /* @var array $cat @var string $error */ ?>
<div class="glass card" style="max-width:640px;margin:2rem auto">
  <h1 style="margin:0 0 1rem;color:var(--fg)"><?= e(t('new_topic')) ?> — <?= e($cat['name_'.($_SESSION['ui_lang']??'tr')] ?? $cat['name_en']) ?></h1>
  <?php if (!empty($error)): ?><p style="color:#fca5a5"><?= e($error) ?></p><?php endif; ?>
  <form method="post" class="grid">
    <?= csrf_field() ?>
    <input name="title" required minlength="3" maxlength="200" placeholder="Başlık">
    <textarea name="body" rows="8" required placeholder="İçerik"></textarea>
    <button type="submit"><?= e(t('submit')) ?></button>
  </form>
</div>
PHP

  cat > "$APP_DIR/views/login.php" <<'PHP'
<?php /* @var string $error */ $config = $GLOBALS['__config']; ?>
<div class="glass card" style="max-width:420px;margin:2rem auto">
  <h1 style="margin:0 0 1rem;color:var(--fg)"><?= e(t('login')) ?></h1>
  <?php if (!empty($error)): ?><p style="color:#fca5a5"><?= e($error) ?></p><?php endif; ?>
  <form method="post" class="grid">
    <?= csrf_field() ?>
    <input name="email" type="email" required placeholder="<?= e(t('email')) ?>" autocomplete="username">
    <input name="password" type="password" required placeholder="<?= e(t('password')) ?>" autocomplete="current-password">
    <button type="submit"><?= e(t('login')) ?></button>
  </form>
  <?php $showErenDev = (($config['default_lang'] ?? '') === 'tr') && (($_SESSION['ui_lang'] ?? '') === 'tr');
  if ($showErenDev):
    $state = bin2hex(random_bytes(24));
    $_SESSION['erendev_state'] = $state;
    $url = $config['erendev']['authorize_url']
         . '?client_id='    . rawurlencode($config['erendev']['client_id'])
         . '&redirect_uri=' . rawurlencode($config['erendev']['redirect_uri'])
         . '&response_type=code'
         . '&scope='        . rawurlencode($config['erendev']['scope'])
         . '&state='        . rawurlencode($state);
  ?>
  <div style="margin-top:1.25rem;padding-top:1.25rem;border-top:1px solid var(--border)">
    <a href="<?= e($url) ?>"><img src="<?= e($config['erendev']['button_svg']) ?>" alt="ErenDev ile Giriş Yap" width="240" height="48" style="height:48px"></a>
  </div>
  <?php endif; ?>
</div>
PHP

  cat > "$APP_DIR/views/register.php" <<'PHP'
<?php /* @var string $error */ $config = $GLOBALS['__config']; ?>
<div class="glass card" style="max-width:420px;margin:2rem auto">
  <h1 style="margin:0 0 1rem;color:var(--fg)"><?= e(t('register')) ?></h1>
  <?php if (!empty($error)): ?><p style="color:#fca5a5"><?= e($error) ?></p><?php endif; ?>
  <form method="post" class="grid">
    <?= csrf_field() ?>
    <input name="username" required minlength="3" maxlength="32" pattern="[A-Za-z0-9_\-]{3,32}" placeholder="<?= e(t('username')) ?>">
    <input name="email" type="email" required placeholder="<?= e(t('email')) ?>">
    <input name="password" type="password" required minlength="10" placeholder="<?= e(t('password')) ?>">
    <input name="hp" type="text" tabindex="-1" style="display:none">
    <button type="submit"><?= e(t('register')) ?></button>
  </form>
  <?php $showErenDev = (($config['default_lang'] ?? '') === 'tr') && (($_SESSION['ui_lang'] ?? '') === 'tr');
  if ($showErenDev): ?>
    <div style="margin-top:1.25rem;padding-top:1.25rem;border-top:1px solid var(--border)">
      <a href="/login.php"><img src="<?= e($config['erendev']['button_svg']) ?>" alt="ErenDev ile Giriş Yap" style="height:48px"></a>
    </div>
  <?php endif; ?>
</div>
PHP

  cat > "$APP_DIR/views/search.php" <<'PHP'
<?php /* @var string $q @var array $result @var array $cats */ ?>
<div class="glass card">
  <h1 style="margin:0 0 1rem;color:var(--fg)"><?= e(t('search_results')) ?>: "<?= e($q) ?>"</h1>
  <form method="get" action="/search.php" class="flex" style="margin-bottom:1rem;flex-wrap:wrap">
    <input name="q" value="<?= e($q) ?>" style="flex:1;min-width:200px">
    <select name="cat" style="width:auto">
      <option value="">— <?= e(t('categories')) ?> —</option>
      <?php foreach ($cats as $c): ?>
        <option value="<?= (int)$c['id'] ?>" <?= (($_GET['cat']??'')==$c['id'])?'selected':'' ?>><?= e($c['name_tr']) ?></option>
      <?php endforeach; ?>
    </select>
    <input name="author" placeholder="author" value="<?= e($_GET['author']??'') ?>" style="width:120px">
    <button type="submit"><?= e(t('search')) ?></button>
  </form>
  <?php if (empty($result['rows'])): ?>
    <p class="muted"><?= e(t('no_results')) ?></p>
  <?php else: foreach ($result['rows'] as $r): ?>
    <div style="padding:1rem 0;border-bottom:1px solid var(--border)">
      <a href="/topic.php?id=<?= (int)$r['topic_id'] ?>" style="font-weight:600"><?= e($r['topic_title']) ?></a>
      <span class="muted" style="font-size:12px"> · @<?= e($r['username']) ?></span>
      <p style="margin:.5rem 0 0"><?= $r['snippet'] ?></p>
    </div>
  <?php endforeach; endif; ?>
</div>
PHP

  cat > "$APP_DIR/views/notifications.php" <<'PHP'
<?php /* @var array $items */ ?>
<div class="glass card">
  <div class="flex" style="justify-content:space-between;margin-bottom:1rem">
    <h1 style="margin:0;color:var(--fg)"><?= e(t('notifications')) ?></h1>
    <form method="post" action="/notifications.php" style="margin:0"><?= csrf_field() ?><input type="hidden" name="action" value="mark_all"><button class="btn-ghost" type="submit"><?= e(t('mark_all_read')) ?></button></form>
  </div>
  <?php if (empty($items)): ?><p class="muted"><?= e(t('no_notifications')) ?></p>
  <?php else: foreach ($items as $n): ?>
    <div style="padding:.75rem 0;border-bottom:1px solid var(--border);<?= $n['read_at']?'opacity:.6':'' ?>">
      <strong><?= e($n['kind']) ?></strong>
      <?php if ($n['actor']): ?><span class="muted">by @<?= e($n['actor']) ?></span><?php endif; ?>
      <?php if ($n['topic_id']): ?><a href="/topic.php?id=<?= (int)$n['topic_id'] ?>" style="margin-left:.5rem">→</a><?php endif; ?>
    </div>
  <?php endforeach; endif; ?>
</div>
PHP

  cat > "$APP_DIR/views/settings.php" <<'PHP'
<?php /* @var array $user */ ?>
<div class="glass card" style="max-width:520px;margin:2rem auto">
  <h1 style="margin:0 0 1rem;color:var(--fg)"><?= e(t('settings')) ?></h1>
  <form method="post" class="grid">
    <?= csrf_field() ?>
    <label><?= e(t('theme')) ?><select name="theme">
      <?php foreach (($GLOBALS['__config']['themes']??['dark']) as $th): ?>
        <option value="<?= e($th) ?>" <?= ($user['theme']??'dark')===$th?'selected':'' ?>><?= e($th) ?></option>
      <?php endforeach; ?>
    </select></label>
    <label><?= e(t('accent')) ?><select name="accent">
      <?php foreach (($GLOBALS['__config']['accents']??['indigo']) as $ac): ?>
        <option value="<?= e($ac) ?>" <?= ($user['accent']??'indigo')===$ac?'selected':'' ?>><?= e($ac) ?></option>
      <?php endforeach; ?>
    </select></label>
    <label class="flex"><input type="checkbox" name="notify_mentions" style="width:auto" <?= ($user['notify_mentions']??1)?'checked':'' ?>> Mentions</label>
    <label class="flex"><input type="checkbox" name="notify_replies" style="width:auto" <?= ($user['notify_replies']??1)?'checked':'' ?>> Replies</label>
    <button type="submit"><?= e(t('save')) ?></button>
  </form>
</div>
PHP

  cat > "$APP_DIR/views/admin.php" <<'PHP'
<?php /* @var array $users @var array $cats @var array $audit */ ?>
<div class="glass card" style="margin-bottom:1rem">
  <h1 style="margin:0 0 1rem;color:var(--fg)">Admin — Users</h1>
  <form method="post" action="/admin.php" class="flex" style="margin-bottom:1rem">
    <?= csrf_field() ?><input type="hidden" name="action" value="bulk_role">
    <input name="ids" placeholder="1,2,3" style="flex:1">
    <select name="role" style="width:auto"><option>member</option><option>moderator</option><option>admin</option></select>
    <button type="submit">Set role</button>
  </form>
  <table><thead><tr><th>ID</th><th>User</th><th>Email</th><th>Role</th></tr></thead><tbody>
    <?php foreach ($users as $u): ?>
      <tr><td><?= (int)$u['id'] ?></td><td>@<?= e($u['username']) ?></td><td class="muted"><?= e($u['email']) ?></td><td><?= e($u['role']) ?></td></tr>
    <?php endforeach; ?>
  </tbody></table>
</div>
<div class="glass card">
  <h2 style="margin:0 0 1rem;color:var(--fg)">Audit log (latest 50)</h2>
  <table><thead><tr><th>When</th><th>Actor</th><th>Action</th></tr></thead><tbody>
    <?php foreach ($audit as $a): ?>
      <tr><td class="muted"><?= date('Y-m-d H:i', (int)$a['ts']) ?></td><td><?= e($a['actor'] ?? '-') ?></td><td><?= e($a['action']) ?></td></tr>
    <?php endforeach; ?>
  </tbody></table>
</div>
PHP
  chown -R root:root "$APP_DIR/views"; chmod -R 0755 "$APP_DIR/views"
  ok "views/"
}

write_public() {
  cat > "$APP_DIR/public/index.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$cats = $db->query("SELECT c.*, (SELECT COUNT(*) FROM topics t WHERE t.category_id=c.id) AS n FROM categories c ORDER BY position, id")->fetchAll();
$title = t('forum');
ob_start(); require LF_ROOT.'/views/home.php'; $content = ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/lang.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
if ($_SERVER['REQUEST_METHOD']!=='POST') { http_response_code(405); exit; }
csrf_verify();
$l = $_POST['lang'] ?? '';
if (in_array($l, $config['available_langs'], true)) { $_SESSION['ui_lang'] = $l; i18n_init($l); }
redirect($_SERVER['HTTP_REFERER'] ?? '/');
PHP

  cat > "$APP_DIR/public/login.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$error='';
if ($_SERVER['REQUEST_METHOD']==='POST') {
  csrf_verify();
  if (!rate_limit($db,'login',client_ip(),$config['rate_limit']['login_per_10min'],600)) {
    http_response_code(429); $error=t('too_many_attempts');
  } else {
    $email = filter_var($_POST['email']??'', FILTER_VALIDATE_EMAIL);
    $pass  = (string)($_POST['password']??'');
    if (!$email||$pass==='') $error=t('missing_info');
    else {
      $st=$db->prepare('SELECT * FROM users WHERE email=?'); $st->execute([$email]); $u=$st->fetch();
      if ($u && password_verify_safe($pass,$u['password_hash'])) { auth_login($u); redirect('/'); }
      $error=t('bad_credentials');
    }
  }
}
ob_start(); require LF_ROOT.'/views/login.php'; $content=ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/register.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$error='';
if ($_SERVER['REQUEST_METHOD']==='POST') {
  csrf_verify();
  if (!empty($_POST['hp'])) { http_response_code(400); exit(t('bot_detected')); }
  if (!rate_limit($db,'register',client_ip(),$config['rate_limit']['register_per_hr'],3600)) {
    http_response_code(429); $error=t('register_limit');
  } else {
    $u=trim((string)($_POST['username']??''));
    $em=filter_var($_POST['email']??'', FILTER_VALIDATE_EMAIL);
    $p=(string)($_POST['password']??'');
    if (!preg_match('/^[A-Za-z0-9_\-]{3,32}$/',$u)) $error=t('bad_username');
    elseif (!$em) $error=t('bad_email');
    elseif (strlen($p)<10) $error=t('weak_password');
    else {
      try {
        $db->prepare('INSERT INTO users(username,email,password_hash,created_at) VALUES(?,?,?,?)')
           ->execute([$u,$em,password_hash_safe($p),time()]);
        $row=$db->prepare('SELECT * FROM users WHERE id=?'); $row->execute([$db->lastInsertId()]);
        auth_login($row->fetch()); redirect('/');
      } catch (PDOException) { $error=t('already_exists'); }
    }
  }
}
ob_start(); require LF_ROOT.'/views/register.php'; $content=ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/logout.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
if ($_SERVER['REQUEST_METHOD']!=='POST') { http_response_code(405); exit; }
csrf_verify(); auth_logout(); redirect('/');
PHP

  cat > "$APP_DIR/public/category.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$slug = trim((string)($_GET['slug'] ?? ''));
if ($slug === '') { http_response_code(400); exit('Missing slug'); }
$st = $db->prepare('SELECT * FROM categories WHERE slug = ?');
$st->execute([$slug]); $cat = $st->fetch();
if (!$cat) { http_response_code(404); exit('Category not found'); }
$page = max(1, (int)($_GET['page'] ?? 1));
$per = 25; $off = ($page - 1) * $per;
$tst = $db->prepare(
  'SELECT t.*, u.username, (SELECT COUNT(*) FROM posts p WHERE p.topic_id = t.id) AS post_count
   FROM topics t JOIN users u ON u.id = t.user_id
   WHERE t.category_id = ? ORDER BY t.is_pinned DESC, t.updated_at DESC LIMIT ? OFFSET ?'
);
$tst->execute([(int)$cat['id'], $per, $off]);
$topics = $tst->fetchAll();
$title = $cat['name_'.($_SESSION['ui_lang'] ?? 'tr')] ?? $cat['name_en'];
ob_start(); require LF_ROOT.'/views/category.php'; $content = ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/topic.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$id = (int)($_GET['id'] ?? 0);
if ($id <= 0) { http_response_code(400); exit('Missing id'); }
$tst = $db->prepare('SELECT t.*, u.username FROM topics t JOIN users u ON u.id=t.user_id WHERE t.id=?');
$tst->execute([$id]); $topic = $tst->fetch();
if (!$topic) { http_response_code(404); exit('Topic not found'); }
$u = auth_user();
if ($_SERVER['REQUEST_METHOD']==='POST' && $u) {
  csrf_verify();
  $action = $_POST['action'] ?? '';
  if ($action === 'toggle_watch') {
    $w = $db->prepare('SELECT 1 FROM topic_watches WHERE user_id=? AND topic_id=?');
    $w->execute([(int)$u['id'], $id]);
    if ($w->fetchColumn()) $db->prepare('DELETE FROM topic_watches WHERE user_id=? AND topic_id=?')->execute([(int)$u['id'], $id]);
    else $db->prepare('INSERT INTO topic_watches(user_id,topic_id,created_at) VALUES(?,?,?)')->execute([(int)$u['id'], $id, time()]);
  } elseif ($action === 'reply' && empty($topic['is_locked'])) {
    $body = trim((string)($_POST['body'] ?? ''));
    if ($body !== '' && rate_limit($db,'post',client_ip(),$config['rate_limit']['post_per_min'],60)) {
      $db->prepare('INSERT INTO posts(topic_id,user_id,body,created_at,updated_at) VALUES(?,?,?,?,?)')
         ->execute([$id, (int)$u['id'], $body, time(), time()]);
      $newPostId = (int)$db->lastInsertId();
      $db->prepare('UPDATE topics SET updated_at=? WHERE id=?')->execute([time(), $id]);
      notif_for_mentions($db, $body, $id, $newPostId, (int)$u['id']);
      notif_for_replies($db, $id, $newPostId, (int)$u['id'], $body);
    }
  }
  redirect('/topic.php?id='.$id);
}
$pst = $db->prepare('SELECT p.*, u.username FROM posts p JOIN users u ON u.id=p.user_id WHERE p.topic_id=? ORDER BY p.created_at ASC');
$pst->execute([$id]); $posts = $pst->fetchAll();
$watching = false;
if ($u) {
  $w = $db->prepare('SELECT 1 FROM topic_watches WHERE user_id=? AND topic_id=?');
  $w->execute([(int)$u['id'], $id]); $watching = (bool)$w->fetchColumn();
}
$title = $topic['title'];
ob_start(); require LF_ROOT.'/views/topic.php'; $content = ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/new-topic.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$u = auth_require();
$catId = (int)($_GET['cat'] ?? 0);
$st = $db->prepare('SELECT * FROM categories WHERE id=?');
$st->execute([$catId]); $cat = $st->fetch();
if (!$cat) { http_response_code(404); exit('Category not found'); }
$error = '';
if ($_SERVER['REQUEST_METHOD']==='POST') {
  csrf_verify();
  $title = trim((string)($_POST['title'] ?? ''));
  $body  = trim((string)($_POST['body'] ?? ''));
  if (strlen($title) < 3 || $body === '') $error = 'Başlık ve içerik gerekli.';
  elseif (rate_limit($db,'post',client_ip(),$config['rate_limit']['post_per_min'],60)) {
    $slug = preg_replace('/[^a-z0-9]+/', '-', strtolower($title));
    $db->prepare('INSERT INTO topics(category_id,user_id,title,slug,created_at,updated_at) VALUES(?,?,?,?,?,?)')
       ->execute([$catId, (int)$u['id'], $title, $slug, time(), time()]);
    $tid = (int)$db->lastInsertId();
    $db->prepare('INSERT INTO posts(topic_id,user_id,body,created_at,updated_at) VALUES(?,?,?,?,?)')
       ->execute([$tid, (int)$u['id'], $body, time(), time()]);
    redirect('/topic.php?id='.$tid);
  } else {
    $error = 'Çok hızlı. Biraz bekleyin.';
  }
}
$title = t('new_topic');
ob_start(); require LF_ROOT.'/views/new-topic.php'; $content = ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/search.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$q = trim((string)($_GET['q'] ?? ''));
$catId = isset($_GET['cat']) && $_GET['cat'] !== '' ? (int)$_GET['cat'] : null;
$author = trim((string)($_GET['author'] ?? ''));
$authorId = null;
if ($author !== '') {
  $a = $db->prepare('SELECT id FROM users WHERE username=?'); $a->execute([$author]);
  $authorId = $a->fetchColumn() ?: null;
}
$page = max(1, (int)($_GET['page'] ?? 1));
$result = $q !== '' ? search_posts($db, $q, $catId, $authorId ? (int)$authorId : null, $page, 20) : ['rows'=>[], 'total'=>0];
$cats = $db->query('SELECT * FROM categories ORDER BY position, id')->fetchAll();
$title = t('search_results');
ob_start(); require LF_ROOT.'/views/search.php'; $content = ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/notifications.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$u = auth_require();
if ($_SERVER['REQUEST_METHOD']==='POST') {
  csrf_verify();
  if (($_POST['action'] ?? '') === 'mark_all') notif_mark_all_read($db, (int)$u['id']);
  redirect('/notifications.php');
}
$items = notif_list($db, (int)$u['id'], 50);
$title = t('notifications');
ob_start(); require LF_ROOT.'/views/notifications.php'; $content = ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/settings.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$u = auth_require();
$row = $db->prepare('SELECT * FROM users WHERE id=?'); $row->execute([(int)$u['id']]); $user = $row->fetch();
if ($_SERVER['REQUEST_METHOD']==='POST') {
  csrf_verify();
  $theme = in_array($_POST['theme']??'', $config['themes'], true) ? $_POST['theme'] : 'dark';
  $accent = in_array($_POST['accent']??'', $config['accents'], true) ? $_POST['accent'] : 'indigo';
  $nm = isset($_POST['notify_mentions']) ? 1 : 0;
  $nr = isset($_POST['notify_replies']) ? 1 : 0;
  $db->prepare('UPDATE users SET theme=?, accent=?, notify_mentions=?, notify_replies=? WHERE id=?')
     ->execute([$theme, $accent, $nm, $nr, (int)$u['id']]);
  redirect('/settings.php');
}
$title = t('settings');
ob_start(); require LF_ROOT.'/views/settings.php'; $content = ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/admin.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$u = auth_admin();
if ($_SERVER['REQUEST_METHOD']==='POST') {
  csrf_verify();
  $action = $_POST['action'] ?? '';
  if ($action === 'bulk_role') {
    $ids = array_filter(array_map('intval', explode(',', $_POST['ids'] ?? '')));
    $role = in_array($_POST['role'] ?? '', ['member','moderator','admin'], true) ? $_POST['role'] : 'member';
    foreach ($ids as $id) {
      $db->prepare('UPDATE users SET role=? WHERE id=?')->execute([$role, $id]);
      audit($db, $u, 'user.role_set', 'user', $id, ['role'=>$role]);
    }
  }
  redirect('/admin.php');
}
$users = $db->query('SELECT id,username,email,role FROM users ORDER BY id DESC LIMIT 200')->fetchAll();
$cats  = $db->query('SELECT * FROM categories ORDER BY position, id')->fetchAll();
$audit = $db->query('SELECT a.*, u.username AS actor FROM audit_log a LEFT JOIN users u ON u.id=a.actor_id ORDER BY a.ts DESC LIMIT 50')->fetchAll();
$title = 'Admin';
ob_start(); require LF_ROOT.'/views/admin.php'; $content = ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/oauth/erendev/callback.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__, 3).'/app/bootstrap.php';
if (($config['default_lang'] ?? '') !== 'tr') { http_response_code(404); exit('Not found.'); }
if (($_SESSION['ui_lang'] ?? '') !== 'tr')     { http_response_code(404); exit('Not found.'); }
$state=(string)($_GET['state']??''); $code=(string)($_GET['code']??'');
if (!$state || !hash_equals($_SESSION['erendev_state']??'', $state)) { http_response_code(400); exit('Invalid state'); }
unset($_SESSION['erendev_state']);
if (!$code) { http_response_code(400); exit('Missing code'); }
$ch=curl_init($config['erendev']['token_url']);
curl_setopt_array($ch,[
  CURLOPT_POST=>true, CURLOPT_RETURNTRANSFER=>true, CURLOPT_TIMEOUT=>15,
  CURLOPT_SSL_VERIFYPEER=>true, CURLOPT_SSL_VERIFYHOST=>2,
  CURLOPT_POSTFIELDS=>http_build_query([
    'grant_type'=>'authorization_code','code'=>$code,
    'redirect_uri'=>$config['erendev']['redirect_uri'],
    'client_id'=>$config['erendev']['client_id'],
    'client_secret'=>$config['erendev']['client_secret'],
  ]),
]);
$resp=curl_exec($ch);
if (curl_errno($ch)) { http_response_code(502); exit('Token exchange failed'); }
$tok=json_decode((string)$resp,true);
if (empty($tok['access_token'])) { http_response_code(502); exit('No token'); }
$ch2=curl_init($config['erendev']['userinfo_url']);
curl_setopt_array($ch2,[
  CURLOPT_RETURNTRANSFER=>true, CURLOPT_TIMEOUT=>10,
  CURLOPT_HTTPHEADER=>['Authorization: Bearer '.$tok['access_token']],
  CURLOPT_SSL_VERIFYPEER=>true,
]);
$u2=json_decode((string)curl_exec($ch2),true);
if (empty($u2['sub'])||empty($u2['email'])) { http_response_code(502); exit('Bad userinfo'); }
$sub=(string)$u2['sub']; $email=(string)$u2['email'];
$username=$u2['preferred_username'] ?? ('ed_'.substr(hash('sha256',$sub),0,10));
$st=$db->prepare('SELECT * FROM users WHERE erendev_sub=? OR email=?');
$st->execute([$sub,$email]); $user=$st->fetch();
if (!$user) {
  $db->prepare('INSERT INTO users(username,email,password_hash,erendev_sub,created_at) VALUES(?,?,?,?,?)')
     ->execute([$username,$email,password_hash_safe(bin2hex(random_bytes(24))),$sub,time()]);
  $st=$db->prepare('SELECT * FROM users WHERE id=?'); $st->execute([$db->lastInsertId()]); $user=$st->fetch();
} else {
  $db->prepare('UPDATE users SET erendev_sub=? WHERE id=?')->execute([$sub,$user['id']]);
}
auth_login($user); redirect('/');
PHP

  chown -R root:root "$APP_DIR/public"
  find "$APP_DIR/public" -type d -exec chmod 0755 {} \;
  find "$APP_DIR/public" -type f -exec chmod 0644 {} \;

  # Verify critical files exist
  for f in index.php category.php topic.php new-topic.php login.php register.php search.php admin.php; do
    [[ -f "$APP_DIR/public/$f" ]] || die "CRITICAL: $APP_DIR/public/$f missing after write_public"
  done
  ok "public/ (all critical files verified)"
}

write_nginx() {
  install -d -o root -g root -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
  SOCK="/run/php/${PHP_VER}-fpm-liteforum.sock"

  cat > "/etc/nginx/sites-available/liteforum" <<NGINX
limit_req_zone \$binary_remote_addr zone=lf_login:10m rate=10r/m;

server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name $DOMAIN;
  root $APP_DIR/public;
  index index.php;

  location /.well-known/acme-challenge/ { allow all; }
  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl http2 default_server;
  listen [::]:443 ssl http2 default_server;
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
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
  ssl_prefer_server_ciphers off;
  ssl_session_cache shared:SSL:10m;
  ssl_session_timeout 1d;
  ssl_session_tickets off;

  add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
  add_header X-Frame-Options "DENY" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header Referrer-Policy "strict-origin-when-cross-origin" always;
  add_header Content-Security-Policy "default-src 'self'; img-src 'self' https://oauth2.erendev.xyz data:; style-src 'self' 'unsafe-inline'; script-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self' https://oauth2.erendev.xyz; connect-src 'self'" always;

  location = /favicon.ico { access_log off; log_not_found off; return 204; }

  location = /login.php {
    limit_req zone=lf_login burst=5 nodelay;
    fastcgi_pass unix:$SOCK;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_param HTTP_PROXY "";
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

  if [[ $SKIP_TLS -eq 1 ]] || [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    sed -i 's/listen 443 ssl http2 default_server;/listen 80 default_server;/' /etc/nginx/sites-available/liteforum
    sed -i 's/listen \[::\]:443 ssl http2 default_server;//' /etc/nginx/sites-available/liteforum
    sed -i '/ssl_/d' /etc/nginx/sites-available/liteforum
    sed -i '/Strict-Transport-Security/d' /etc/nginx/sites-available/liteforum
    sed -i 's/return 301 https:\/\/\$host\$request_uri;//' /etc/nginx/sites-available/liteforum
    # Remove the first (redirect) server block if we're HTTP-only
    awk 'BEGIN{RS="server \\{";ORS="server {"} NR>1{if(prev ~ /return 301 https/) {next} print prev; prev=$0} END{print prev}' /etc/nginx/sites-available/liteforum > /tmp/lf-nginx 2>/dev/null || true
  fi

  ln -sf /etc/nginx/sites-available/liteforum /etc/nginx/sites-enabled/liteforum
  rm -f /etc/nginx/sites-enabled/default
  ok "Nginx config written"
}

write_phpfpm() {
  POOL="/etc/php/${PHP_VER#php}/fpm/pool.d/liteforum.conf"
  install -d -o root -g root -m 0755 "$(dirname "$POOL")"
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
php_admin_value[error_log] = $LOG_DIR/php-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
php_admin_flag[expose_php] = off
php_admin_flag[allow_url_include] = off
php_admin_flag[allow_url_fopen] = off
php_admin_value[open_basedir] = $APP_DIR:$DATA_DIR:/tmp:/var/log/liteforum
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec,show_source,phpinfo
php_admin_value[upload_tmp_dir] = $DATA_DIR/tmp
php_admin_value[session.save_path] = $DATA_DIR/sessions
php_admin_value[session.cookie_httponly] = 1
php_admin_value[session.cookie_secure] = 1
php_admin_value[session.cookie_samesite] = "Strict"
php_admin_value[session.use_strict_mode] = 1
php_admin_value[session.use_only_cookies] = 1
php_admin_value[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 64
php_admin_value[opcache.validate_timestamps] = 1
php_admin_value[opcache.revalidate_freq] = 0
FPM
  chown root:root "$POOL"; chmod 0644 "$POOL"
  ok "PHP-FPM pool"
}

setup_ufw() {
  [[ $NO_FIREWALL -eq 1 ]] && { warn "UFW skipped"; return; }
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp comment 'SSH'
  ufw allow 80/tcp comment 'HTTP'
  ufw allow 443/tcp comment 'HTTPS'
  ufw --force enable
  ok "UFW enabled"
}

setup_fail2ban() {
  install -d -o root -g root -m 0755 /etc/fail2ban/jail.d /etc/fail2ban/filter.d
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
F2B
  systemctl enable --now fail2ban 2>/dev/null || true
  ok "Fail2ban"
}

setup_sysctl() {
  install -d -o root -g root -m 0755 /etc/sysctl.d
  cat > /etc/sysctl.d/99-liteforum.conf <<'SYS'
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
net.ipv4.tcp_syncookies = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
SYS
  sysctl --system >/dev/null 2>&1 || true
  ok "Sysctl"
}

setup_tls() {
  [[ $SKIP_TLS -eq 1 ]] && { warn "TLS skipped"; return; }
  install -d -o root -g root -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled

  # HTTP-only config for ACME challenge
  cat > /etc/nginx/sites-available/liteforum.http <<HTTP
server {
  listen 80;
  server_name $DOMAIN;
  root $APP_DIR/public;
  location /.well-known/acme-challenge/ { allow all; }
  location / { return 301 https://\$host\$request_uri; }
}
HTTP
  ln -sf /etc/nginx/sites-available/liteforum.http /etc/nginx/sites-enabled/liteforum.http
  rm -f /etc/nginx/sites-enabled/liteforum
  nginx -t 2>/dev/null && systemctl reload nginx

  if certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect 2>&1 | tee -a "$INSTALL_LOG"; then
    ok "TLS issued"
    rm -f /etc/nginx/sites-enabled/liteforum.http
    ln -sf /etc/nginx/sites-available/liteforum /etc/nginx/sites-enabled/liteforum
    nginx -t && systemctl reload nginx
    systemctl enable --now certbot.timer 2>/dev/null || true
  else
    warn "Certbot failed — continuing with HTTP only"
    rm -f /etc/nginx/sites-enabled/liteforum.http
    # Rebuild nginx config in HTTP-only mode
    write_nginx
    ln -sf /etc/nginx/sites-available/liteforum /etc/nginx/sites-enabled/liteforum
    nginx -t && systemctl reload nginx
  fi
}

seed_data() {
  DB="$DATA_DIR/liteforum.db"
  sqlite3 "$DB" <<SQL
INSERT OR IGNORE INTO categories(slug,name_tr,name_en,position) VALUES
 ('general','Genel','General',10),
 ('announcements','Duyurular','Announcements',20),
 ('support','Destek','Support',30);
SQL
  HASH="$(php -r 'echo password_hash($argv[1], PASSWORD_ARGON2ID);' "$ADMIN_PASS")"
  sqlite3 "$DB" <<SQL
INSERT INTO users(username,email,password_hash,role,created_at)
VALUES('admin','$ADMIN_EMAIL','$HASH','admin',strftime('%s','now'))
ON CONFLICT(email) DO UPDATE SET role='admin';
SQL
  chown "$SVC_USER:$SVC_USER" "$DB"* 2>/dev/null; chmod 0600 "$DB"* 2>/dev/null
  ok "Seed"
}

start_services() {
  nginx -t || die "Nginx config invalid"
  systemctl enable "$PHP_VER-fpm" nginx >/dev/null 2>&1 || true
  systemctl restart "$PHP_VER-fpm"
  systemctl restart nginx
  ok "Services up"
}

verify_site() {
  sleep 2
  # Local check via host header
  if curl -fsS -H "Host: $DOMAIN" "http://127.0.0.1/" -o /dev/null 2>/dev/null; then
    ok "HTTP homepage OK"
  else
    warn "HTTP homepage check failed — check /var/log/liteforum/error.log"
  fi
  # Verify category.php responds via HTTP
  if curl -fsS -H "Host: $DOMAIN" "http://127.0.0.1/category.php?slug=general" -o /dev/null 2>/dev/null; then
    ok "category.php OK"
  else
    warn "category.php check failed — investigate /var/log/liteforum/error.log"
  fi
  # Verify topic endpoint reachable
  if curl -fsS -H "Host: $DOMAIN" "http://127.0.0.1/login.php" -o /dev/null 2>/dev/null; then
    ok "login.php OK"
  else
    warn "login.php check failed"
  fi
}

[[ $DRY_RUN -eq 1 ]] && {
  cat <<EOF
DRY-RUN:
  Domain : $DOMAIN
  Lang   : $LANG_CODE
  Admin  : $ADMIN_EMAIL
  AppDir : $APP_DIR
  DataDir: $DATA_DIR
  TLS    : $([[ $SKIP_TLS -eq 1 ]] && echo skip || echo yes)
EOF
  exit 0
}

preflight
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
write_phpfpm
setup_ufw
setup_fail2ban
setup_sysctl
seed_data
setup_tls
write_nginx          # ensure final config matches TLS status
start_services
verify_site

CRED_FILE="/root/liteforum-credentials.txt"
cat > "$CRED_FILE" <<EOF
LiteForum Installation
======================
URL             : https://$DOMAIN  (or http:// if TLS failed)
Install lang    : $LANG_CODE
ErenDev OAuth   : $([[ $LANG_CODE == tr ]] && echo "shown only when UI=tr" || echo "hidden (credentials not present)")
Admin email     : $ADMIN_EMAIL
Admin password  : $ADMIN_PASS
App key         : $APP_KEY
OAuth client_id : $OAuth_CLIENT_ID
OAuth secret    : $OAuth_CLIENT_SECRET
DB              : $DATA_DIR/liteforum.db
Logs            : $LOG_DIR

Troubleshooting:
  - If site shows 404: sudo tail -30 /var/log/liteforum/error.log
  - Verify files exist: ls -la $APP_DIR/public/
  - Verify sockets: ls /run/php/
  - Reload: sudo systemctl reload nginx $PHP_VER-fpm
EOF
chmod 0600 "$CRED_FILE"

echo
echo "============================================================"
echo " LiteForum ready → https://$DOMAIN"
echo " Admin: $ADMIN_EMAIL / $ADMIN_PASS"
echo " Credentials: $CRED_FILE"
echo "============================================================"
