#!/usr/bin/env bash
# =============================================================================
# LiteForum — Ultra-Secure One-Shot Installer (English)
#   curl -fsSL https://get.erendev.xyz/install.sh | sudo bash -s -- \
#        --domain forum.example.com --email you@example.com --lang tr --admin admin@example.com
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
LiteForum Installer (English)
  --domain <fqdn>       Domain (Let's Encrypt TLS is provisioned if ports 80/443 are open)
  --email <mail>        Contact email for Let's Encrypt + admin
  --admin <mail>        Admin email (password is auto-generated)
  --lang <tr|en>        Install language — 'tr' enables ErenDev OAuth credentials
  --skip-tls            Skip TLS (HTTP only, HSTS disabled)
  --no-firewall         Skip UFW setup
  --dry-run             Print plan only
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
[[ $EUID -eq 0 ]] || die "root required (use sudo)."
[[ -n "$DOMAIN" ]] || die "--domain is required (needed for TLS)."
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"; EMAIL="${EMAIL:-$ADMIN_EMAIL}"

log "LiteForum installer starting — domain=$DOMAIN lang=$LANG_CODE admin=$ADMIN_EMAIL dry-run=$DRY_RUN"

preflight() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    log "sqlite3 CLI not found — installing it now..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -qq
    apt-get install -y -qq sqlite3 || die "Failed to install sqlite3 CLI"
  fi
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 CLI still missing after install"
  ok "sqlite3 CLI available: $(sqlite3 --version | awk '{print $1}')"
}

detect_os() {
  . /etc/os-release
  case "$ID" in ubuntu|debian) ;; *) die "Only Ubuntu/Debian are supported. Found: $ID";; esac
  ARCH="$(dpkg --print-architecture)"
  [[ "$ARCH" == "amd64" || "$ARCH" == "arm64" ]] || die "Unsupported architecture: $ARCH"
  ok "OS=$PRETTY_NAME ARCH=$ARCH"
}

install_packages() {
  log "Installing packages (apt)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq || die "apt-get update failed"
  apt-get upgrade -y -qq || warn "apt-get upgrade had issues (continuing)"

  PHP_VER="$(apt-cache search --names-only '^php[0-9]+\.[0-9]+-fpm$' | sort -V | tail -1 | awk -F- '{print $1}')"
  [[ -n "$PHP_VER" ]] || PHP_VER="php8.2"
  log "PHP version: $PHP_VER"

  if ! apt-get install -y -qq \
      nginx nginx-common \
      "$PHP_VER-fpm" "$PHP_VER-cli" "$PHP_VER-sqlite3" "$PHP_VER-curl" \
      "$PHP_VER-mbstring" "$PHP_VER-xml" "$PHP_VER-intl" "$PHP_VER-opcache" \
      "$PHP_VER-bcmath" "$PHP_VER-gd" \
      sqlite3 curl ca-certificates openssl \
      ufw fail2ban unattended-upgrades apt-listchanges \
      certbot python3-certbot-nginx \
      logrotate rsync jq; then
    die "Core package installation failed — see output above"
  fi

  apt-get install -y -qq libnginx-mod-http-headers-more-filter libnginx-mod-http-limit-req \
    2>>"$INSTALL_LOG" || warn "Optional nginx modules not installed (non-fatal)"

  command -v nginx   >/dev/null 2>&1 || die "nginx binary missing after install"
  [[ -f /etc/nginx/nginx.conf ]]      || die "/etc/nginx/nginx.conf missing after install"
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 CLI missing after install"
  command -v php     >/dev/null 2>&1 || die "php CLI missing after install"

  install -d -o root -g root -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
  ok "Packages installed (nginx + sqlite3 + php verified)"
}

create_user() {
  id "$SVC_USER" &>/dev/null || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin --user-group "$SVC_USER"
  usermod -aG www-data "$SVC_USER" || true
  ok "Service user: $SVC_USER"
}

create_dirs() {
  install -d -o root      -g root      -m 0755 "$APP_DIR" "$APP_DIR"/{public,app,config,lang,views,plugins}
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
  [[ -f "$DB" ]] && { warn "DB exists, leaving untouched."; return; }
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 CLI missing — aborting DB init"
  log "Initializing SQLite (WAL, busy_timeout, FTS5, notifications)..."
  sqlite3 "$DB" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA synchronous=NORMAL;
PRAGMA foreign_keys=ON;
PRAGMA temp_store=MEMORY;
PRAGMA mmap_size=134217728;
PRAGMA journal_size_limit=67108864;

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
  name_tr TEXT NOT NULL,
  name_en TEXT NOT NULL,
  name_fr TEXT,
  name_de TEXT,
  name_es TEXT,
  name_ar TEXT,
  position INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE topics(
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
CREATE TABLE posts(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES users(id),
  body TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX idx_topics_cat ON topics(category_id, updated_at DESC);
CREATE INDEX idx_topics_user ON topics(user_id);
CREATE INDEX idx_posts_topic ON posts(topic_id, created_at ASC);
CREATE INDEX idx_posts_user ON posts(user_id);

CREATE TABLE rate_limits(id INTEGER PRIMARY KEY AUTOINCREMENT, bucket TEXT NOT NULL, ip TEXT NOT NULL, ts INTEGER NOT NULL);
CREATE INDEX idx_rate ON rate_limits(bucket, ip, ts);

CREATE TABLE notifications(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK(kind IN ('mention','reply','mod_action','system')),
  topic_id INTEGER REFERENCES topics(id) ON DELETE CASCADE,
  post_id INTEGER REFERENCES posts(id) ON DELETE CASCADE,
  actor_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
  snippet TEXT,
  read_at INTEGER,
  created_at INTEGER NOT NULL
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
  action TEXT NOT NULL,
  target_kind TEXT,
  target_id INTEGER,
  meta TEXT,
  ip TEXT,
  ts INTEGER NOT NULL
);
CREATE INDEX idx_audit_ts ON audit_log(ts DESC);
CREATE INDEX idx_audit_actor ON audit_log(actor_id, ts DESC);

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
  ok "SQLite ready: $DB"
}

write_env() {
  ENV="$APP_DIR/config/config.php"
  cat > "$ENV" <<PHP
<?php
return [
    'app_name'          => 'LiteForum',
    'default_lang'      => '$LANG_CODE',
    'available_langs'   => ['tr','en','fr','de','es','ar'],
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
    'rate_limit' => ['login_per_10min'=>8, 'post_per_min'=>6, 'register_per_hr'=>5],
    'themes' => ['dark','light','high-contrast'],
    'accents' => ['indigo','emerald','rose','amber','sky'],
    'admin_email' => '$ADMIN_EMAIL',
];
PHP
  chown "$SVC_USER:$SVC_USER" "$ENV"; chmod 0640 "$ENV"
  ok "config.php written (0640)"
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
  'too_many_attempts'=>'Çok fazla deneme, sonra tekrar deneyin.','missing_info'=>'Eksik bilgi.',
  'bad_credentials'=>'E-posta veya şifre hatalı.','bot_detected'=>'Bot tespit edildi.',
  'register_limit'=>'Bu IP için kayıt limiti aşıldı.','bad_username'=>'Kullanıcı adı 3–32 karakter olmalı.',
  'bad_email'=>'Geçerli bir e-posta girin.','weak_password'=>'Şifre en az 10 karakter olmalı.',
  'already_exists'=>'Bu kullanıcı adı veya e-posta zaten kayıtlı.',
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
  'too_many_attempts'=>'Too many attempts, please try again later.','missing_info'=>'Missing information.',
  'bad_credentials'=>'Incorrect email or password.','bot_detected'=>'Bot detected.',
  'register_limit'=>'Registration limit exceeded for this IP.','bad_username'=>'Username must be 3–32 chars.',
  'bad_email'=>'Please enter a valid email address.','weak_password'=>'Password must be at least 10 characters.',
  'already_exists'=>'This username or email is already registered.',
];
PHP
  cat > "$APP_DIR/lang/fr.php" <<'PHP'
<?php return [
  'forum'=>'Forum','login'=>'Se connecter','register'=>"S'inscrire",'logout'=>'Se déconnecter',
  'username'=>"Nom d'utilisateur",'email'=>'E-mail','password'=>'Mot de passe',
  'categories'=>'Catégories','topics'=>'Sujets','posts'=>'Messages',
  'new_topic'=>'Nouveau sujet','reply'=>'Répondre','search'=>'Rechercher...','submit'=>'Envoyer',
  'notifications'=>'Notifications','mark_all_read'=>'Tout marquer comme lu','no_notifications'=>'Aucune notification',
  'watch_topic'=>'Suivre le sujet','unwatch_topic'=>'Ne plus suivre',
  'theme'=>'Thème','accent'=>"Couleur d'accent",'settings'=>'Paramètres','save'=>'Enregistrer',
  'search_results'=>'Résultats','no_results'=>'Aucun résultat','search_placeholder'=>'Rechercher...',
  'erendev_login'=>'Se connecter avec ErenDev',
  'too_many_attempts'=>'Trop de tentatives, réessayez plus tard.','missing_info'=>'Informations manquantes.',
  'bad_credentials'=>'E-mail ou mot de passe incorrect.','bot_detected'=>'Bot détecté.',
  'register_limit'=>"Limite d'inscription dépassée pour cette IP.",'bad_username'=>"Nom d'utilisateur 3–32 caractères.",
  'bad_email'=>'Saisissez un e-mail valide.','weak_password'=>'Le mot de passe doit faire au moins 10 caractères.',
  'already_exists'=>'Ce nom ou e-mail est déjà enregistré.',
];
PHP
  cat > "$APP_DIR/lang/de.php" <<'PHP'
<?php return [
  'forum'=>'Forum','login'=>'Anmelden','register'=>'Registrieren','logout'=>'Abmelden',
  'username'=>'Benutzername','email'=>'E-Mail','password'=>'Passwort',
  'categories'=>'Kategorien','topics'=>'Themen','posts'=>'Beiträge',
  'new_topic'=>'Neues Thema','reply'=>'Antworten','search'=>'Suchen...','submit'=>'Absenden',
  'notifications'=>'Benachrichtigungen','mark_all_read'=>'Alle als gelesen markieren','no_notifications'=>'Keine Benachrichtigungen',
  'watch_topic'=>'Thema beobachten','unwatch_topic'=>'Nicht mehr beobachten',
  'theme'=>'Design','accent'=>'Akzentfarbe','settings'=>'Einstellungen','save'=>'Speichern',
  'search_results'=>'Suchergebnisse','no_results'=>'Keine Ergebnisse','search_placeholder'=>'Suchen...',
  'erendev_login'=>'Mit ErenDev anmelden',
  'too_many_attempts'=>'Zu viele Versuche, bitte später erneut.','missing_info'=>'Fehlende Angaben.',
  'bad_credentials'=>'E-Mail oder Passwort falsch.','bot_detected'=>'Bot erkannt.',
  'register_limit'=>'Registrierungslimit für diese IP erreicht.','bad_username'=>'Benutzername 3–32 Zeichen.',
  'bad_email'=>'Bitte gültige E-Mail eingeben.','weak_password'=>'Passwort mindestens 10 Zeichen.',
  'already_exists'=>'Benutzername oder E-Mail bereits registriert.',
];
PHP
  cat > "$APP_DIR/lang/es.php" <<'PHP'
<?php return [
  'forum'=>'Foro','login'=>'Iniciar sesión','register'=>'Registrarse','logout'=>'Cerrar sesión',
  'username'=>'Usuario','email'=>'Correo','password'=>'Contraseña',
  'categories'=>'Categorías','topics'=>'Temas','posts'=>'Mensajes',
  'new_topic'=>'Nuevo tema','reply'=>'Responder','search'=>'Buscar...','submit'=>'Enviar',
  'notifications'=>'Notificaciones','mark_all_read'=>'Marcar todo como leído','no_notifications'=>'Sin notificaciones',
  'watch_topic'=>'Seguir tema','unwatch_topic'=>'Dejar de seguir',
  'theme'=>'Tema','accent'=>'Color de acento','settings'=>'Ajustes','save'=>'Guardar',
  'search_results'=>'Resultados','no_results'=>'Sin resultados','search_placeholder'=>'Buscar...',
  'erendev_login'=>'Iniciar sesión con ErenDev',
  'too_many_attempts'=>'Demasiados intentos, inténtalo más tarde.','missing_info'=>'Información incompleta.',
  'bad_credentials'=>'Correo o contraseña incorrectos.','bot_detected'=>'Bot detectado.',
  'register_limit'=>'Límite de registro alcanzado para esta IP.','bad_username'=>'Usuario 3–32 caracteres.',
  'bad_email'=>'Introduce un correo válido.','weak_password'=>'La contraseña debe tener al menos 10 caracteres.',
  'already_exists'=>'Este usuario o correo ya está registrado.',
];
PHP
  cat > "$APP_DIR/lang/ar.php" <<'PHP'
<?php return [
  'forum'=>'المنتدى','login'=>'تسجيل الدخول','register'=>'إنشاء حساب','logout'=>'تسجيل الخروج',
  'username'=>'اسم المستخدم','email'=>'البريد الإلكتروني','password'=>'كلمة المرور',
  'categories'=>'الأقسام','topics'=>'المواضيع','posts'=>'المنشورات',
  'new_topic'=>'موضوع جديد','reply'=>'رد','search'=>'بحث...','submit'=>'إرسال',
  'notifications'=>'الإشعارات','mark_all_read'=>'تحديد الكل كمقروء','no_notifications'=>'لا توجد إشعارات',
  'watch_topic'=>'متابعة الموضوع','unwatch_topic'=>'إلغاء المتابعة',
  'theme'=>'المظهر','accent'=>'لون التمييز','settings'=>'الإعدادات','save'=>'حفظ',
  'search_results'=>'نتائج البحث','no_results'=>'لا نتائج','search_placeholder'=>'بحث...',
  'erendev_login'=>'تسجيل الدخول عبر ErenDev',
  'too_many_attempts'=>'محاولات كثيرة، حاول لاحقًا.','missing_info'=>'معلومات ناقصة.',
  'bad_credentials'=>'البريد أو كلمة المرور غير صحيحة.','bot_detected'=>'تم رصد روبوت.',
  'register_limit'=>'تم تجاوز حد التسجيل لهذا العنوان.','bad_username'=>'اسم المستخدم 3–32 حرفًا.',
  'bad_email'=>'أدخل بريدًا صالحًا.','weak_password'=>'كلمة المرور 10 أحرف على الأقل.',
  'already_exists'=>'هذا الاسم أو البريد مسجل بالفعل.',
];
PHP
  chown -R root:root "$APP_DIR/lang"; chmod 0644 "$APP_DIR/lang"/*.php
}

write_app() {
  cat > "$APP_DIR/app/bootstrap.php" <<'PHP'
<?php
declare(strict_types=1);
define('LF_ROOT', dirname(__DIR__));
$config = require LF_ROOT . '/config/config.php';
require LF_ROOT . '/app/db.php'; require LF_ROOT . '/app/csrf.php';
require LF_ROOT . '/app/auth.php'; require LF_ROOT . '/app/i18n.php';
require LF_ROOT . '/app/helpers.php'; require LF_ROOT . '/app/notifications.php';
require LF_ROOT . '/app/search.php'; require LF_ROOT . '/app/theme.php';

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
     ->execute([$actor['id']??null, $action, $kind, $id, json_encode($meta, JSON_UNESCAPED_UNICODE), client_ip(), time()]);
}
PHP

  cat > "$APP_DIR/app/csrf.php" <<'PHP'
<?php
declare(strict_types=1);
function csrf_init(string $k): void { $_SESSION['csrf_token'] ??= bin2hex(random_bytes(32)); $_SESSION['csrf_key'] ??= $k; }
function csrf_token(): string { return $_SESSION['csrf_token']; }
function csrf_field(): string { return '<input type="hidden" name="_csrf" value="'.e(csrf_token()).'">'; }
function csrf_verify(): void {
  $t=$_POST['_csrf']??''; if (!is_string($t)||!hash_equals($_SESSION['csrf_token']??'',$t)) { http_response_code(419); exit('Invalid CSRF token.'); }
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
  $_SESSION=[]; if (ini_get('session.use_cookies')) { $p=session_get_cookie_params(); setcookie(session_name(),'',time()-42000,$p['path'],$p['domain'],$p['secure'],$p['httponly']); }
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
  $theme  = $u['theme']  ?? ($_SESSION['theme']  ?? 'dark');
  $accent = $u['accent'] ?? ($_SESSION['accent'] ?? 'indigo');
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
    if ($uid = $st->fetchColumn()) {
      notif_create($db, (int)$uid, 'mention', $topicId, $postId, $actorId, $body);
    }
  }
}
function notif_for_replies(PDO $db, int $topicId, int $postId, int $actorId, string $body): void {
  $st = $db->prepare('SELECT user_id FROM topic_watches WHERE topic_id = ? AND user_id != ?');
  $st->execute([$topicId, $actorId]);
  foreach ($st->fetchAll(PDO::FETCH_COLUMN) as $uid) {
    notif_create($db, (int)$uid, 'reply', $topicId, $postId, $actorId, $body);
  }
}
function notif_unread_count(PDO $db, int $userId): int {
  $st = $db->prepare('SELECT COUNT(*) FROM notifications WHERE user_id=? AND read_at IS NULL');
  $st->execute([$userId]); return (int)$st->fetchColumn();
}
function notif_list(PDO $db, int $userId, int $limit=50): array {
  $st = $db->prepare('SELECT n.*, u.username AS actor FROM notifications n LEFT JOIN users u ON u.id=n.actor_id
    WHERE n.user_id=? ORDER BY n.created_at DESC LIMIT ?');
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
  if ($authorId)   { $sql .= ' AND p.user_id = ?';     $params[] = $authorId; }
  $sql .= ' ORDER BY rank LIMIT ? OFFSET ?';
  $params[] = $per; $params[] = max(0, ($page-1)*$per);
  $st = $db->prepare($sql);
  try { $st->execute($params); } catch (PDOException $e) { return ['rows'=>[], 'total'=>0]; }
  $rows = $st->fetchAll();
  $csql = 'SELECT COUNT(*) FROM posts_fts JOIN posts p ON p.id=posts_fts.rowid JOIN topics t ON t.id=p.topic_id WHERE posts_fts MATCH ?';
  $cparams = [$q];
  if ($categoryId) { $csql .= ' AND t.category_id = ?'; $cparams[] = $categoryId; }
  if ($authorId)   { $csql .= ' AND p.user_id = ?';     $cparams[] = $authorId; }
  $cst = $db->prepare($csql); $cst->execute($cparams);
  return ['rows'=>$rows, 'total'=>(int)$cst->fetchColumn()];
}
PHP
  chown -R root:root "$APP_DIR/app"; chmod -R 0755 "$APP_DIR/app"
}

write_views() {
  cat > "$APP_DIR/views/layout.php" <<'PHP'
<?php /* @var string $content @var string $title */ $u = auth_user(); ?>
<!doctype html>
<html lang="<?= e($_SESSION['ui_lang'] ?? 'tr') ?>" dir="<?= ($_SESSION['ui_lang'] ?? 'tr')==='ar'?'rtl':'ltr' ?>">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="strict-origin-when-cross-origin">
<title><?= e($title ?? 'LiteForum') ?> · LiteForum</title>
<style nonce="<?= e(csp_nonce()) ?>">
  :root { <?= theme_css_vars() ?> }
  body{background:var(--bg);color:var(--fg);font-family:ui-sans-serif,system-ui,-apple-system,sans-serif;margin:0}
  .bg-pattern{background-image:radial-gradient(var(--border) 1px,transparent 1px);background-size:32px 32px}
  .glass{background:var(--panel);backdrop-filter:blur(8px);border:1px solid var(--border);border-radius:1rem;box-shadow:0 25px 50px -12px rgba(0,0,0,.6)}
  a{color:var(--accent-400);text-decoration:none}a:hover{text-decoration:underline}
  .container{max-width:1100px;margin:0 auto;padding:2rem 1.25rem;position:relative;z-index:1}
  header.nav{position:sticky;top:0;z-index:10;border-bottom:1px solid var(--border);background:var(--panel);backdrop-filter:blur(8px)}
  header.nav .inner{max-width:1100px;margin:0 auto;padding:1rem 1.25rem;display:flex;justify-content:space-between;align-items:center;gap:.75rem;flex-wrap:wrap}
  .logo{display:flex;gap:.5rem;align-items:center;color:var(--fg);font-weight:600}
  .logo .mark{width:32px;height:32px;border-radius:.5rem;background:var(--accent-500);display:flex;align-items:center;justify-content:center;font-weight:700;color:#fff}
  input,textarea,select{background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:.5rem;padding:.55rem .75rem;width:100%;box-sizing:border-box;font:inherit}
  button,.btn{background:var(--accent-500);color:#fff;border:0;border-radius:.5rem;padding:.6rem 1rem;cursor:pointer;font-weight:600}
  button:hover,.btn:hover{background:var(--accent-600);text-decoration:none}
  .btn-ghost{background:transparent;border:1px solid var(--border);color:var(--fg)}
  .muted{color:#94a3b8}.card{padding:1.5rem}.flex{display:flex;gap:.75rem;align-items:center}.grid{display:grid;gap:1rem}
  table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:.75rem 1rem;border-bottom:1px solid var(--border)}
  code{background:var(--bg);padding:1px 6px;border-radius:4px;color:var(--accent-400);font-size:.9em}
  .badge-notif{display:inline-block;background:#ef4444;color:#fff;border-radius:999px;font-size:11px;padding:1px 6px;margin-left:4px}
  mark{background:var(--accent-500);color:#fff;padding:0 2px;border-radius:2px}
</style>
</head>
<body class="bg-pattern" style="position:relative;min-height:100vh">
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
<footer class="container muted" style="font-size:.8rem;padding-bottom:3rem">LiteForum · MIT</footer>
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
  <?php if (empty($topics)): ?>
    <p class="muted">Henüz konu yok.</p>
  <?php else: ?>
    <table>
      <thead><tr><th>Konu</th><th>Yazar</th><th>Mesaj</th><th>Tarih</th></tr></thead>
      <tbody>
      <?php foreach ($topics as $t): ?>
        <tr>
          <td><?php if ((int)$t['is_pinned']): ?>📌 <?php endif; ?><a href="/topic.php?id=<?= (int)$t['id'] ?>"><?= e($t['title']) ?></a></td>
          <td class="muted">@<?= e($t['username']) ?></td>
          <td class="muted"><?= (int)$t['post_count'] ?></td>
          <td class="muted"><?= date('Y-m-d', (int)$t['updated_at']) ?></td>
        </tr>
      <?php endforeach; ?>
      </tbody>
    </table>
  <?php endif; ?>
</div>
PHP

  cat > "$APP_DIR/views/topic.php" <<'PHP'
<?php /* @var array $topic @var array $posts @var bool $watching */ ?>
<div class="glass card" style="margin-bottom:1rem">
  <h1 style="margin:0 0 .5rem;color:var(--fg)"><?= e($topic['title']) ?></h1>
  <p class="muted" style="margin:0;font-size:13px">
    @<?= e($topic['username']) ?> · <?= date('Y-m-d H:i', (int)$topic['created_at']) ?>
  </p>
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
  <?php
  $showErenDev = (($config['default_lang'] ?? '') === 'tr')
              && (($_SESSION['ui_lang'] ?? '') === 'tr');
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
  <h1 style="margin:0 0 1rem;color:var(--fg)"><?= e(t('register')) ?></h1>
  <?php if (!empty($error)): ?><p style="color:#fca5a5"><?= e($error) ?></p><?php endif; ?>
  <form method="post" class="grid">
    <?= csrf_field() ?>
    <input name="username" required minlength="3" maxlength="32" pattern="[A-Za-z0-9_\-]{3,32}" placeholder="<?= e(t('username')) ?>">
    <input name="email" type="email" required placeholder="<?= e(t('email')) ?>" autocomplete="email">
    <input name="password" type="password" required minlength="10" placeholder="<?= e(t('password')) ?>" autocomplete="new-password">
    <input name="hp" type="text" tabindex="-1" autocomplete="off" style="display:none" aria-hidden="true">
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
    <input name="q" value="<?= e($q) ?>" placeholder="<?= e(t('search_placeholder')) ?>" style="flex:1;min-width:200px">
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
  <?php else: ?>
    <p class="muted" style="font-size:12px"><?= (int)$result['total'] ?> results</p>
    <?php foreach ($result['rows'] as $r): ?>
      <div style="padding:1rem 0;border-bottom:1px solid var(--border)">
        <a href="/topic.php?id=<?= (int)$r['topic_id'] ?>" style="font-weight:600"><?= e($r['topic_title']) ?></a>
        <span class="muted" style="font-size:12px"> · @<?= e($r['username']) ?></span>
        <p style="margin:.5rem 0 0"><?= $r['snippet'] ?></p>
      </div>
    <?php endforeach; ?>
  <?php endif; ?>
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
      <p class="muted" style="font-size:13px;margin:.25rem 0 0"><?= e($n['snippet'] ?? '') ?></p>
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
    <label><?= e(t('theme')) ?>
      <select name="theme">
        <?php foreach (($GLOBALS['__config']['themes']??['dark']) as $th): ?>
          <option value="<?= e($th) ?>" <?= ($user['theme']??'dark')===$th?'selected':'' ?>><?= e($th) ?></option>
        <?php endforeach; ?>
      </select>
    </label>
    <label><?= e(t('accent')) ?>
      <select name="accent">
        <?php foreach (($GLOBALS['__config']['accents']??['indigo']) as $ac): ?>
          <option value="<?= e($ac) ?>" <?= ($user['accent']??'indigo')===$ac?'selected':'' ?>><?= e($ac) ?></option>
        <?php endforeach; ?>
      </select>
    </label>
    <label class="flex"><input type="checkbox" name="notify_mentions" style="width:auto" <?= ($user['notify_mentions']??1)?'checked':'' ?>> Mentions</label>
    <label class="flex"><input type="checkbox" name="notify_replies" style="width:auto" <?= ($user['notify_replies']??1)?'checked':'' ?>> Replies</label>
    <label class="flex"><input type="checkbox" name="notify_digest" style="width:auto" <?= ($user['notify_digest']??0)?'checked':'' ?>> Digest</label>
    <button type="submit"><?= e(t('save')) ?></button>
  </form>
</div>
PHP

  cat > "$APP_DIR/views/admin.php" <<'PHP'
<?php /* @var array $users @var array $cats @var array $audit */ ?>
<div class="glass card" style="margin-bottom:1rem">
  <h1 style="margin:0 0 1rem;color:var(--fg)">Admin — Users</h1>
  <form method="post" action="/admin.php" class="flex" style="margin-bottom:1rem;flex-wrap:wrap">
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
<div class="glass card" style="margin-bottom:1rem">
  <h2 style="margin:0 0 1rem;color:var(--fg)">Categories (drag order)</h2>
  <form method="post" action="/admin.php" class="flex" style="margin-bottom:1rem">
    <?= csrf_field() ?><input type="hidden" name="action" value="reorder">
    <input name="order" placeholder="3,1,2" style="flex:1"><button type="submit">Reorder</button>
  </form>
  <form method="post" action="/admin.php" class="flex" style="flex-wrap:wrap">
    <?= csrf_field() ?><input type="hidden" name="action" value="new_cat">
    <input name="slug" placeholder="slug" style="width:120px">
    <input name="name_tr" placeholder="TR" style="width:120px">
    <input name="name_en" placeholder="EN" style="width:120px">
    <button type="submit">Add</button>
  </form>
</div>
<div class="glass card">
  <h2 style="margin:0 0 1rem;color:var(--fg)">Audit log (latest 50)</h2>
  <table><thead><tr><th>When</th><th>Actor</th><th>Action</th><th>Target</th></tr></thead><tbody>
    <?php foreach ($audit as $a): ?>
      <tr><td class="muted"><?= date('Y-m-d H:i', (int)$a['ts']) ?></td><td><?= e($a['actor'] ?? '-') ?></td><td><?= e($a['action']) ?></td><td class="muted"><?= e($a['target_kind'] ?? '') ?><?= $a['target_id']?'#'.(int)$a['target_id']:'' ?></td></tr>
    <?php endforeach; ?>
  </tbody></table>
</div>
PHP
  chown -R root:root "$APP_DIR/views"; chmod -R 0755 "$APP_DIR/views"
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
if ($slug === '') { http_response_code(400); exit('Missing category slug.'); }
$st = $db->prepare('SELECT * FROM categories WHERE slug = ?'); $st->execute([$slug]); $cat = $st->fetch();
if (!$cat) { http_response_code(404); exit('Category not found.'); }

$page = max(1, (int)($_GET['page'] ?? 1));
$per = 25; $off = ($page - 1) * $per;
$tst = $db->prepare(
  'SELECT t.*, u.username, (SELECT COUNT(*) FROM posts p WHERE p.topic_id = t.id) AS post_count
   FROM topics t JOIN users u ON u.id = t.user_id
   WHERE t.category_id = ?
   ORDER BY t.is_pinned DESC, t.updated_at DESC
   LIMIT ? OFFSET ?'
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
if ($id <= 0) { http_response_code(400); exit('Missing topic id.'); }

$tst = $db->prepare('SELECT t.*, u.username FROM topics t JOIN users u ON u.id=t.user_id WHERE t.id=?');
$tst->execute([$id]); $topic = $tst->fetch();
if (!$topic) { http_response_code(404); exit('Topic not found.'); }

$u = auth_user();
if ($_SERVER['REQUEST_METHOD']==='POST' && $u) {
  csrf_verify();
  $action = $_POST['action'] ?? '';
  if ($action === 'toggle_watch') {
    $w = $db->prepare('SELECT 1 FROM topic_watches WHERE user_id=? AND topic_id=?');
    $w->execute([(int)$u['id'], $id]);
    if ($w->fetchColumn()) {
      $db->prepare('DELETE FROM topic_watches WHERE user_id=? AND topic_id=?')->execute([(int)$u['id'], $id]);
    } else {
      $db->prepare('INSERT INTO topic_watches(user_id,topic_id,created_at) VALUES(?,?,?)')->execute([(int)$u['id'], $id, time()]);
    }
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
  $nd = isset($_POST['notify_digest']) ? 1 : 0;
  $db->prepare('UPDATE users SET theme=?, accent=?, notify_mentions=?, notify_replies=?, notify_digest=? WHERE id=?')
     ->execute([$theme, $accent, $nm, $nr, $nd, (int)$u['id']]);
  audit($db, $u, 'user.settings_update');
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
  } elseif ($action === 'reorder') {
    $order = array_filter(array_map('intval', explode(',', $_POST['order'] ?? '')));
    foreach ($order as $i => $id) $db->prepare('UPDATE categories SET position=? WHERE id=?')->execute([$i*10, $id]);
    audit($db, $u, 'category.reorder');
  } elseif ($action === 'new_cat') {
    $slug = preg_replace('/[^a-z0-9\-]/','', strtolower($_POST['slug'] ?? ''));
    if ($slug) {
      try { $db->prepare('INSERT INTO categories(slug,name_tr,name_en,position) VALUES(?,?,?,999)')
             ->execute([$slug, $_POST['name_tr'] ?? $slug, $_POST['name_en'] ?? $slug]);
            audit($db, $u, 'category.create', 'category', (int)$db->lastInsertId());
      } catch (PDOException) {}
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

  mkdir -p "$APP_DIR/public/oauth/erendev"
  cat > "$APP_DIR/public/oauth/erendev/callback.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
if (($config['default_lang'] ?? '') !== 'tr') { http_response_code(404); exit('Not found.'); }
if (($_SESSION['ui_lang'] ?? '') !== 'tr')     { http_response_code(404); exit('Not found.'); }

$state=(string)($_GET['state']??''); $code=(string)($_GET['code']??'');
if (!$state||!hash_equals($_SESSION['erendev_state']??'',$state)) { http_response_code(400); exit('Invalid state.'); }
unset($_SESSION['erendev_state']); if (!$code) { http_response_code(400); exit('Missing code.'); }

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
$resp=curl_exec($ch); if (curl_errno($ch)) { http_response_code(502); exit('Token exchange failed.'); }
$tok=json_decode((string)$resp,true); if (empty($tok['access_token'])) { http_response_code(502); exit('No access token.'); }

$ch2=curl_init($config['erendev']['userinfo_url']);
curl_setopt_array($ch2,[
  CURLOPT_RETURNTRANSFER=>true, CURLOPT_TIMEOUT=>10,
  CURLOPT_HTTPHEADER=>['Authorization: Bearer '.$tok['access_token']],
  CURLOPT_SSL_VERIFYPEER=>true,
]);
$u=json_decode((string)curl_exec($ch2),true);
if (empty($u['sub'])||empty($u['email'])) { http_response_code(502); exit('Bad userinfo.'); }

$sub=(string)$u['sub']; $email=(string)$u['email'];
$username=$u['preferred_username'] ?? ('ed_'.substr(hash('sha256',$sub),0,10));

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
}

write_nginx() {
  install -d -o root -g root -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
  SOCK="/run/php/${PHP_VER}-fpm-liteforum.sock"
  cat > "/etc/nginx/sites-available/liteforum" <<NGINX
limit_req_zone \$binary_remote_addr zone=lf_login:10m rate=10r/m;
limit_req_zone \$binary_remote_addr zone=lf_general:10m rate=30r/s;

server {
  listen 80; listen [::]:80; server_name $DOMAIN;
  return 301 https://\$host\$request_uri;
}
server {
  listen 443 ssl http2; listen [::]:443 ssl http2;
  server_name $DOMAIN; root $APP_DIR/public; index index.php;
  server_tokens off; charset utf-8;
  client_max_body_size 10m; client_body_timeout 15s; client_header_timeout 15s;
  send_timeout 20s; keepalive_timeout 30s;

  ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
  ssl_trusted_certificate /etc/letsencrypt/live/$DOMAIN/chain.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
  ssl_prefer_server_ciphers off; ssl_session_cache shared:SSL:10m; ssl_session_timeout 1d;
  ssl_session_tickets off; ssl_stapling on; ssl_stapling_verify on;

  add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
  add_header X-Frame-Options "DENY" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header Referrer-Policy "strict-origin-when-cross-origin" always;
  add_header Permissions-Policy "geolocation=(), microphone=(), camera=(), interest-cohort=()" always;
  add_header Cross-Origin-Opener-Policy "same-origin" always;
  add_header Cross-Origin-Resource-Policy "same-origin" always;
  add_header Content-Security-Policy "default-src 'self'; img-src 'self' https://oauth2.erendev.xyz data:; style-src 'self' 'unsafe-inline'; script-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self' https://oauth2.erendev.xyz; connect-src 'self'" always;

  location = /install.php {
    allow 127.0.0.1; allow ::1; deny all;
    fastcgi_pass unix:$SOCK; include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_param HTTP_PROXY ""; fastcgi_hide_header X-Powered-By;
  }
  location = /login.php {
    limit_req zone=lf_login burst=5 nodelay;
    fastcgi_pass unix:$SOCK; include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_hide_header X-Powered-By;
  }
  location ~ \.php$ {
    try_files \$uri =404; fastcgi_pass unix:$SOCK; include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_param HTTP_PROXY ""; fastcgi_hide_header X-Powered-By;
    fastcgi_read_timeout 30s;
  }
  location / { try_files \$uri \$uri/ /index.php?\$query_string; }
  location ~ /\.(?!well-known) { deny all; }
  location ~* \.(env|log|sqlite|db|sql|bak|ini|conf|md|git)$ { deny all; }
  location ~ /(config|app|lang|views|storage)/ { deny all; }

  access_log $LOG_DIR/access.log; error_log $LOG_DIR/error.log warn;
}
NGINX
  [[ $SKIP_TLS -eq 1 ]] && {
    sed -i 's/return 301 https:\/\/\$host\$request_uri;//' /etc/nginx/sites-available/liteforum
    sed -i 's/listen 443 ssl http2;/listen 80;/' /etc/nginx/sites-available/liteforum
    sed -i '/ssl_/d;/Strict-Transport-Security/d' /etc/nginx/sites-available/liteforum
    sed -i 's#ssl_certificate.*##;s#ssl_certificate_key.*##' /etc/nginx/sites-available/liteforum
  }
  ln -sf /etc/nginx/sites-available/liteforum /etc/nginx/sites-enabled/liteforum
  rm -f /etc/nginx/sites-enabled/default
  chown root:root /etc/nginx/sites-available/liteforum
  chmod 0644 /etc/nginx/sites-available/liteforum
  ok "Nginx configured"
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
  chown root:root "$POOL"; chmod 0644 "$POOL"
  ok "PHP-FPM pool written"
}

setup_ufw() {
  [[ $NO_FIREWALL -eq 1 ]] && { warn "UFW skipped"; return; }
  ufw --force reset >/dev/null
  ufw default deny incoming; ufw default allow outgoing
  ufw allow 22/tcp comment 'SSH'; ufw allow 80/tcp comment 'HTTP'; ufw allow 443/tcp comment 'HTTPS'
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

setup_sysctl() {
  install -d -o root -g root -m 0755 /etc/sysctl.d
  cat > /etc/sysctl.d/99-liteforum.conf <<'SYS'
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

setup_backup() {
  install -d -o root -g root -m 0755 /etc/cron.d
  cat > /etc/cron.d/liteforum-backup <<CRON
30 3 * * * $SVC_USER sqlite3 $DATA_DIR/liteforum.db "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1
45 3 * * * root tar czf - $DATA_DIR | openssl enc -aes-256-cbc -pbkdf2 -salt -pass file:/etc/liteforum/backup.pass > $DATA_DIR/backups/lf-\$(date +\\%F).tar.gz.enc 2>/dev/null && find $DATA_DIR/backups -name 'lf-*.tar.gz.enc' -mtime +14 -delete
CRON
  install -d -o root -g root -m 0700 /etc/liteforum
  openssl rand -base64 32 > /etc/liteforum/backup.pass
  chmod 0600 /etc/liteforum/backup.pass
  ok "Backups scheduled (14-day retention)"
}

setup_tls() {
  [[ $SKIP_TLS -eq 1 ]] && { warn "TLS skipped"; return; }
  install -d -o root -g root -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
  cat > /etc/nginx/sites-available/liteforum.http <<HTTP
server { listen 80; server_name $DOMAIN; root $APP_DIR/public;
  location /.well-known/acme-challenge/ { allow all; }
  location / { return 301 https://\$host\$request_uri; } }
HTTP
  ln -sf /etc/nginx/sites-available/liteforum.http /etc/nginx/sites-enabled/liteforum.http
  rm -f /etc/nginx/sites-enabled/liteforum
  nginx -t && systemctl reload nginx
  if certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect; then
    ok "TLS certificate issued"
  else
    warn "Certbot failed — the forum will run on HTTP for now."
    warn "Fix firewall/security-list on your host and re-run:"
    warn "  sudo certbot --nginx -d $DOMAIN -m $EMAIL --agree-tos --non-interactive --redirect"
    [[ -f /etc/nginx/sites-available/liteforum ]] || write_nginx
    rm -f /etc/nginx/sites-enabled/liteforum.http
    ln -sf /etc/nginx/sites-available/liteforum /etc/nginx/sites-enabled/liteforum
    sed -i 's/listen 443 ssl http2;/listen 80;/;s/listen \[::\]:443 ssl http2;//;s#ssl_certificate.*##;s#ssl_certificate_key.*##;s#ssl_trusted_certificate.*##;s#return 301 https://\$host\$request_uri;##;s#Strict-Transport-Security.*##' /etc/nginx/sites-available/liteforum
    nginx -t && systemctl reload nginx
    return 0
  fi
  rm -f /etc/nginx/sites-enabled/liteforum.http
  ln -sf /etc/nginx/sites-available/liteforum /etc/nginx/sites-enabled/liteforum
  nginx -t && systemctl reload nginx
  systemctl enable --now certbot.timer 2>/dev/null || true
}

seed_data() {
  DB="$DATA_DIR/liteforum.db"
  sqlite3 "$DB" <<SQL
INSERT OR IGNORE INTO categories(slug,name_tr,name_en,name_fr,name_de,name_es,name_ar,position) VALUES
 ('general','Genel','General','Général','Allgemein','General','عام',10),
 ('announcements','Duyurular','Announcements','Annonces','Ankündigungen','Anuncios','إعلانات',20),
 ('support','Destek','Support','Support','Hilfe','Soporte','دعم',30);
SQL
  HASH="$(php -r 'echo password_hash($argv[1], PASSWORD_ARGON2ID);' "$ADMIN_PASS")"
  sqlite3 "$DB" <<SQL
INSERT INTO users(username,email,password_hash,role,created_at)
VALUES('admin','$ADMIN_EMAIL','$HASH','admin',strftime('%s','now'))
ON CONFLICT(email) DO UPDATE SET role='admin';
SQL
  chown "$SVC_USER:$SVC_USER" "$DB"* 2>/dev/null; chmod 0600 "$DB"* 2>/dev/null
  ok "Seed complete"
}

start_services() {
  nginx -t || die "Nginx config is invalid"
  systemctl enable --now "$PHP_VER-fpm" nginx unattended-upgrades
  systemctl restart "$PHP_VER-fpm" nginx
  ok "Services are up"
}

[[ $DRY_RUN -eq 1 ]] && { cat <<EOF
DRY-RUN plan:
  Domain : $DOMAIN
  Lang   : $LANG_CODE  (ErenDev button: install=tr AND ui=tr)
  Admin  : $ADMIN_EMAIL
  AppDir : $APP_DIR
  DataDir: $DATA_DIR
  TLS    : $([[ $SKIP_TLS -eq 1 ]] && echo skip || echo yes)
EOF
exit 0; }

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
write_nginx
write_phpfpm
setup_ufw
setup_fail2ban
setup_sysctl
setup_backup
seed_data
setup_tls
start_services

CRED_FILE="/root/liteforum-credentials.txt"
cat > "$CRED_FILE" <<EOF
LiteForum — Installation Summary ($(date -Is))
===============================================
URL              : https://$DOMAIN
Install language : $LANG_CODE
ErenDev OAuth    : $([[ $LANG_CODE == tr ]] && echo "VISIBLE only when UI language is Turkish" || echo "HIDDEN (no credentials — install was $LANG_CODE)")
UI languages     : tr, en, fr, de, es, ar (switcher in header)
Themes           : dark, light, high-contrast
Accents          : indigo, emerald, rose, amber, sky
Notifications    : mentions, replies, watch-topic, per-user settings
Search           : FTS5 bm25 ranking, snippets with <mark>, category + author filters
Admin UI         : bulk roles, category reorder, audit log viewer
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
  echo " ErenDev OAuth: VISIBLE only when UI language is Turkish"
else
  echo " ErenDev OAuth: HIDDEN (no credentials — install was $LANG_CODE)"
fi
echo " Admin login: $ADMIN_EMAIL"
echo " Admin pass : $ADMIN_PASS   → $CRED_FILE"
echo "============================================================"
