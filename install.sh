#!/usr/bin/env bash
# =============================================================================
# LiteForum — One-Shot Installer (v5)
# =============================================================================
set -Eeuo pipefail
umask 027
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

DOMAIN=""; ADMIN_EMAIL=""; EMAIL=""
LANG_CODE="tr"
DRY_RUN=0; SKIP_TLS=0; NO_FIREWALL=0; CLOUDFLARED=0
CF_TOKEN=""; CF_LOGIN=0; CF_NAMED=0
HTTP_PORT=80
HAS_TLS=0; CF_URL=""; PUBLIC_BASE=""; PHP_VER=""
APP_DIR="/var/www/liteforum"; DATA_DIR="/var/lib/liteforum"; LOG_DIR="/var/log/liteforum"
SVC_USER="liteforum"; INSTALL_LOG="/var/log/liteforum-install.log"
mkdir -p "$(dirname "$INSTALL_LOG")"; touch "$INSTALL_LOG"

log()  { printf "\e[36m[%s]\e[0m %s\n" "$(date +%H:%M:%S)" "$*" | tee -a "$INSTALL_LOG"; }
ok()   { printf "\e[32m[OK]\e[0m  %s\n" "$*" | tee -a "$INSTALL_LOG"; }
warn() { printf "\e[33m[WARN]\e[0m %s\n" "$*" | tee -a "$INSTALL_LOG"; }
die()  { printf "\e[31m[FATAL]\e[0m %s\n" "$*" | tee -a "$INSTALL_LOG"; exit 1; }

usage() { cat <<EOT
LiteForum Installer
  --domain <fqdn>   --email <mail>   --admin <mail>   --lang <tr|en>
  --skip-tls        --no-firewall    --dry-run        -h|--help
  --cloudflared     (no --domain: expose via Cloudflare quick tunnel)
  --cf-token <tok>  (with --domain: Cloudflare named tunnel, no certbot)
  --cf-login        (with --domain: Cloudflare login link, auto DNS + tunnel)
  --port <n>        (HTTP port, default 80; needs --skip-tls or a tunnel mode)
EOT
exit 0; }

need_val() { [[ $# -ge 2 && -n "$2" ]] || die "Missing value for $1"; }

while [[ $# -gt 0 ]]; do case "$1" in
  --domain)      need_val "$@"; DOMAIN="$2"; shift 2;;
  --email)       need_val "$@"; EMAIL="$2"; shift 2;;
  --admin)       need_val "$@"; ADMIN_EMAIL="$2"; shift 2;;
  --lang)        need_val "$@"; LANG_CODE="$2"; shift 2;;
  --skip-tls)    SKIP_TLS=1; shift;;
  --no-firewall) NO_FIREWALL=1; shift;;
  --dry-run)     DRY_RUN=1; shift;;
  --cloudflared) CLOUDFLARED=1; shift;;
  --cf-token)    need_val "$@"; CF_TOKEN="$2"; shift 2;;
  --cf-login)    CF_LOGIN=1; shift;;
  --port)        need_val "$@"; HTTP_PORT="$2"; shift 2;;
  -h|--help)     usage;;
  *) die "Unknown arg: $1";;
esac; done

[[ "$LANG_CODE" == "tr" || "$LANG_CODE" == "en" ]] || die "--lang must be tr|en"
[[ $EUID -eq 0 ]] || die "root required"

if [[ -n "$CF_TOKEN" && $CF_LOGIN -eq 1 ]]; then die "Use either --cf-token or --cf-login, not both"; fi
if [[ -n "$CF_TOKEN" || $CF_LOGIN -eq 1 ]]; then
  [[ -n "$DOMAIN" ]] || die "--cf-token / --cf-login require --domain"
  [[ $CLOUDFLARED -eq 0 ]] || die "Tunnel options cannot be combined with --cloudflared"
  CF_NAMED=1; SKIP_TLS=1
elif [[ -z "$DOMAIN" ]]; then
  [[ $CLOUDFLARED -eq 1 ]] || die "--domain required (or --cloudflared, or --cf-token with --domain)"
  DOMAIN="localhost"; SKIP_TLS=1
elif [[ $CLOUDFLARED -eq 1 ]]; then
  die "Use either --domain or --cloudflared, not both"
fi
[[ "$HTTP_PORT" =~ ^[0-9]+$ ]] && (( HTTP_PORT >= 1 && HTTP_PORT <= 65535 )) || die "--port must be 1-65535"
if [[ $SKIP_TLS -eq 0 && "$HTTP_PORT" != "80" ]]; then
  die "--port needs --skip-tls or a tunnel mode (Let's Encrypt requires port 80)"
fi
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN}}"; EMAIL="${EMAIL:-$ADMIN_EMAIL}"

validate_inputs() {
  DOMAIN="${DOMAIN,,}"
  local re_dom='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
  local re_mail='^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*$'
  if [[ "$DOMAIN" != "localhost" ]]; then
    [[ "$DOMAIN" =~ $re_dom ]] || die "Invalid --domain: $DOMAIN"
  fi
  [[ "$ADMIN_EMAIL" =~ $re_mail ]] || die "Invalid --admin email"
  [[ "$EMAIL" =~ $re_mail ]]       || die "Invalid --email"
  if [[ -n "$CF_TOKEN" ]]; then
    [[ "$CF_TOKEN" =~ ^[A-Za-z0-9+/=_.-]{20,}$ ]] || die "Invalid --cf-token format"
  fi
}
validate_inputs

preflight() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    apt-get update -y -qq
    apt-get install -y -qq sqlite3 || die "sqlite3 install failed"
  fi
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 missing"
  ok "sqlite3 available"
}

detect_os() {
  # shellcheck disable=SC1091
  . /etc/os-release
  case "$ID" in ubuntu|debian) ;; *) die "Only Ubuntu/Debian supported. Found: $ID";; esac
  ok "OS=$PRETTY_NAME"
}

install_packages() {
  apt-get update -y -qq || die "apt update failed"
  apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade || warn "upgrade issues (continuing)"
  PHP_VER="$(apt-cache search --names-only '^php[0-9]+\.[0-9]+-fpm$' | awk -F- '{print $1}' | sort -V | tail -1)"
  [[ -n "$PHP_VER" ]] || PHP_VER="php8.2"
  apt-get install -y -qq \
      nginx nginx-common \
      "$PHP_VER-fpm" "$PHP_VER-cli" "$PHP_VER-sqlite3" "$PHP_VER-curl" \
      "$PHP_VER-mbstring" "$PHP_VER-xml" "$PHP_VER-intl" "$PHP_VER-opcache" \
      "$PHP_VER-bcmath" "$PHP_VER-gd" \
      sqlite3 curl ca-certificates openssl \
      ufw fail2ban unattended-upgrades \
      certbot python3-certbot-nginx logrotate rsync jq \
    || die "Package install failed"
  command -v nginx >/dev/null || die "nginx binary missing"
  command -v php   >/dev/null || die "php missing"
  ok "Packages installed ($PHP_VER)"
}

create_user() {
  id "$SVC_USER" &>/dev/null || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin --user-group "$SVC_USER"
  usermod -aG www-data "$SVC_USER" || true
  ok "Service user: $SVC_USER"
}

create_dirs() {
  install -d -o root -g root -m 0755 /var/www
  install -d -o root -g root -m 0755 "$APP_DIR" "$APP_DIR"/{public,app,config,lang,views}
  install -d -o root -g root -m 0755 "$APP_DIR/public/assets" "$APP_DIR/public/oauth/erendev"
  install -d -o "$SVC_USER" -g "$SVC_USER" -m 0700 "$DATA_DIR" "$DATA_DIR"/{sessions,tmp,backups,uploads}
  install -d -o "$SVC_USER" -g adm -m 0750 "$LOG_DIR"
}

gen_secrets() {
  APP_KEY="$(openssl rand -hex 32)"
  ADMIN_PASS="$(openssl rand -hex 12)"
  OAUTH_CLIENT_ID="ed_app_$(openssl rand -hex 8)"
  OAUTH_CLIENT_SECRET="eds_$(openssl rand -hex 24)"
  BOT_SUFFIX="$(openssl rand -hex 3)"
  ok "Secrets generated"
}

init_sqlite() {
  DB="$DATA_DIR/liteforum.db"
  if [[ -f "$DB" ]]; then die "Database already exists at $DB. Remove it or use a fresh install."; fi
  sqlite3 "$DB" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE roles(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  color_hex TEXT NOT NULL DEFAULT '#6366f1' CHECK(length(color_hex)=7 AND substr(color_hex,1,1)='#'),
  power_level INTEGER NOT NULL DEFAULT 0 CHECK(power_level BETWEEN 0 AND 99)
);

CREATE TABLE users(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL UNIQUE,
  email TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member' CHECK(role IN ('member','moderator','admin')),
  role_id INTEGER REFERENCES roles(id) ON DELETE SET NULL,
  is_verified INTEGER NOT NULL DEFAULT 0,
  banned INTEGER NOT NULL DEFAULT 0,
  ban_reason TEXT,
  erendev_sub TEXT UNIQUE,
  theme TEXT NOT NULL DEFAULT 'dark' CHECK(theme IN ('dark','light','high-contrast')),
  accent TEXT NOT NULL DEFAULT 'indigo' CHECK(accent IN ('indigo','emerald','rose','amber','sky')),
  bio TEXT DEFAULT '',
  avatar_color TEXT DEFAULT '#6366f1',
  email_verified INTEGER NOT NULL DEFAULT 1,
  notify_mentions INTEGER NOT NULL DEFAULT 1,
  notify_replies INTEGER NOT NULL DEFAULT 1,
  notify_reactions INTEGER NOT NULL DEFAULT 1,
  notify_digest INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  last_seen_at INTEGER,
  last_login_at INTEGER
);

CREATE TABLE presence(
  pkey TEXT PRIMARY KEY,
  user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
  last_seen INTEGER NOT NULL
);
CREATE INDEX idx_presence_seen ON presence(last_seen);

CREATE TABLE categories(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  slug TEXT NOT NULL UNIQUE,
  name_tr TEXT NOT NULL, name_en TEXT NOT NULL,
  name_fr TEXT, name_de TEXT, name_es TEXT, name_ar TEXT,
  description_tr TEXT DEFAULT '', description_en TEXT DEFAULT '',
  description_fr TEXT, description_de TEXT, description_es TEXT, description_ar TEXT,
  icon TEXT DEFAULT '💬',
  position INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE topics(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES users(id),
  title TEXT NOT NULL, slug TEXT NOT NULL,
  is_pinned INTEGER NOT NULL DEFAULT 0,
  is_locked INTEGER NOT NULL DEFAULT 0,
  views INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE INDEX idx_topics_cat ON topics(category_id, is_pinned DESC, updated_at DESC);

CREATE TABLE posts(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES users(id),
  body TEXT NOT NULL,
  is_deleted INTEGER NOT NULL DEFAULT 0,
  edited_at INTEGER,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
);
CREATE INDEX idx_posts_topic ON posts(topic_id, created_at ASC);

CREATE TABLE post_reactions(
  post_id INTEGER NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  emoji TEXT NOT NULL CHECK(emoji IN ('👍','❤️','🔥','😂','😮')),
  created_at INTEGER NOT NULL,
  PRIMARY KEY(post_id, user_id, emoji)
);

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

CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);

CREATE TABLE password_resets(
  token TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL,
  used INTEGER NOT NULL DEFAULT 0
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

CREATE TABLE tags(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE COLLATE NOCASE,
  slug TEXT NOT NULL UNIQUE
);
CREATE VIRTUAL TABLE tags_fts USING fts5(name, content='tags', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
CREATE TRIGGER tags_ai AFTER INSERT ON tags BEGIN
  INSERT INTO tags_fts(rowid,name) VALUES (new.id,new.name);
END;
CREATE TRIGGER tags_ad AFTER DELETE ON tags BEGIN
  INSERT INTO tags_fts(tags_fts,rowid,name) VALUES('delete',old.id,old.name);
END;
CREATE TRIGGER tags_au AFTER UPDATE ON tags BEGIN
  INSERT INTO tags_fts(tags_fts,rowid,name) VALUES('delete',old.id,old.name);
  INSERT INTO tags_fts(rowid,name) VALUES (new.id,new.name);
END;

CREATE TABLE topic_tags(
  topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
  tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  PRIMARY KEY(topic_id, tag_id)
);
CREATE INDEX idx_topic_tags_tag ON topic_tags(tag_id, topic_id);

CREATE TABLE category_tags(
  category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  PRIMARY KEY(category_id, tag_id)
);

CREATE TABLE uploads(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  post_id INTEGER REFERENCES posts(id) ON DELETE SET NULL,
  stored_name TEXT NOT NULL UNIQUE,
  original_name TEXT NOT NULL,
  mime TEXT NOT NULL,
  size INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE ai_providers(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  slug TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL,
  adapter TEXT NOT NULL,
  base_url TEXT NOT NULL DEFAULT '',
  default_model TEXT NOT NULL DEFAULT '',
  api_key_enc TEXT NOT NULL DEFAULT '',
  enabled INTEGER NOT NULL DEFAULT 1,
  builtin INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE ai_profiles(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  provider_id INTEGER NOT NULL REFERENCES ai_providers(id) ON DELETE CASCADE,
  model TEXT NOT NULL DEFAULT '',
  system_prompt TEXT NOT NULL,
  category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
  user_id INTEGER NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL
);

CREATE TABLE ai_jobs(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  topic_id INTEGER NOT NULL REFERENCES topics(id) ON DELETE CASCADE,
  post_id INTEGER REFERENCES posts(id) ON DELETE CASCADE,
  profile_id INTEGER NOT NULL REFERENCES ai_profiles(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'queued' CHECK(status IN ('queued','running','done','failed')),
  error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX idx_ai_jobs_status ON ai_jobs(status, id);

INSERT INTO settings(key,value) VALUES
  ('app_name','LiteForum'),
  ('app_tagline','A lightweight, modern forum'),
  ('schema_version','5'),
  ('ai_enabled','0'),
  ('turnstile_enabled','0'),('turnstile_site_key',''),('turnstile_secret_enc','');
SQL
  chown "$SVC_USER:$SVC_USER" "$DB"* 2>/dev/null || true
  chmod 0600 "$DB"* 2>/dev/null || true
  ok "SQLite schema v5: $DB"
}

setup_ai_cron() {
  cat > /etc/cron.d/liteforum-ai <<CRON
SHELL=/bin/bash
* * * * * $SVC_USER /usr/bin/php $APP_DIR/app/ai-worker.php >>$LOG_DIR/ai-worker.log 2>&1
CRON
  chmod 0644 /etc/cron.d/liteforum-ai
  ok "AI worker scheduled (every minute)"
}

write_i18n() {
  cat > "$APP_DIR/lang/en.php" <<'PHP'
<?php return [
  'forum'=>'Forum','login'=>'Log in','register'=>'Sign up','logout'=>'Log out',
  'username'=>'Username','email'=>'Email','password'=>'Password','bio'=>'Bio',
  'categories'=>'Categories','topics'=>'Topics','posts'=>'Posts','views'=>'Views',
  'new_topic'=>'New topic','reply'=>'Reply','search'=>'Search','submit'=>'Submit',
  'notifications'=>'Notifications','mark_all_read'=>'Mark all as read','no_notifications'=>'No notifications',
  'watch_topic'=>'Watch topic','unwatch_topic'=>'Unwatch','topic_watch_on'=>'You are now watching this topic.','topic_watch_off'=>'Stopped watching.',
  'theme'=>'Theme','accent'=>'Accent color','avatar_color'=>'Avatar color','settings'=>'Settings','save'=>'Save',
  'search_results'=>'Search results','no_results'=>'No results','search_placeholder'=>'Search...',
  'home'=>'Home','activity'=>'Activity','stats'=>'Statistics','profile'=>'Profile',
  'recent_topics'=>'Recent topics','latest_posts'=>'Latest posts','online_users'=>'Online',
  'members'=>'Members','total_topics'=>'Topics','total_posts'=>'Posts','total_users'=>'Members',
  'joined'=>'Joined','last_seen'=>'Last seen','popular'=>'Popular',
  'title'=>'Title','body'=>'Body','post_reply'=>'Post reply','back'=>'Back','reply_to_topic'=>'Reply to topic',
  'all'=>'All','tag_search'=>'Search tags...','tags_max'=>'Tags (max 5)','image_upload'=>'Image (jpg, png, gif, webp; max 5 MB)',
  'title_body_required'=>'Title and body are required.','post_too_fast'=>'You are posting too fast. Please wait.',
  'rate_wait'=>'Too fast. Please wait a moment.','verified_account'=>'Verified account',
  'erendev_login'=>'Sign in with ErenDev','too_many_attempts'=>'Too many attempts.','missing_info'=>'Missing information.',
  'bad_credentials'=>'Incorrect email or password.','bot_detected'=>'Bot detected.',
  'register_limit'=>'Registration limit exceeded.','bad_username'=>'Username must be 3-32 characters.',
  'bad_email'=>'Enter a valid email.','weak_password'=>'Password must be at least 10 characters.',
  'already_exists'=>'Already registered.','saved'=>'Saved.','not_found'=>'Not found.',
  'settings_saved'=>'Settings saved.','site_name'=>'Site name','site_tagline'=>'Site tagline',
  'admin_settings'=>'Site settings','admin_panel'=>'Admin panel',
  'tab_general'=>'General','tab_ai'=>'AI assistant','tab_turnstile'=>'Turnstile','tab_users'=>'Users & roles',
  'tab_categories'=>'Categories','tab_audit'=>'Audit log',
  'admin_audit'=>'Audit log','roles'=>'Roles','admin_users'=>'Users','admin_categories'=>'Category management',
  'add_category'=>'Add category','edit_category'=>'Edit category','delete_category'=>'Delete category',
  'delete_confirm'=>'Are you sure you want to delete this?','yes_delete'=>'Yes, delete',
  'no_topics_yet'=>'No topics yet.','loading'=>'Loading...','delete'=>'Delete','edit'=>'Edit',
  'slug'=>'Slug','icon'=>'Icon','position'=>'Position','description'=>'Description',
  'password_change'=>'Change password','current_password'=>'Current password',
  'new_password'=>'New password','confirm_password'=>'Confirm new password',
  'password_changed'=>'Password updated.','password_mismatch'=>'Passwords do not match.',
  'password_wrong'=>'Current password is incorrect.',
  'forgot_password'=>'Forgot password','reset_password'=>'Reset password',
  'reset_link_sent'=>'A reset link has been sent (if the address is registered).',
  'reset_invalid'=>'Link is invalid or expired.','reset_complete'=>'Password reset. You can now log in.',
  'pin'=>'Pin','unpin'=>'Unpin','lock'=>'Lock','unlock'=>'Unlock',
  'delete_post'=>'Delete post','delete_topic'=>'Delete topic',
  'ban_user'=>'Ban user','unban_user'=>'Unban user','banned'=>'Banned',
  'mod_only'=>'You do not have permission.',
  'edited'=>'edited','deleted_post'=>'[deleted]',
  'email_taken'=>'Email already in use.','invalid_token'=>'Invalid token.',
  'banned_msg'=>'Your account is banned.',
  'ai_enabled'=>'Enabled','ai_global'=>'AI assistant is enabled','ai_hint'=>'Each enabled profile replies with its provider. Replies are generated by a worker every minute.',
  'ai_providers'=>'Providers','ai_profiles'=>'Profiles','ai_add_provider'=>'Add custom provider',
  'ai_provider'=>'Provider','ai_adapter'=>'Protocol','ai_base_url'=>'Base URL','ai_model'=>'Model',
  'ai_default_model'=>'Default model','ai_api_key'=>'API key','ai_key_saved'=>'Key saved (type a new one to replace)',
  'ai_no_key_needed'=>'No key needed','ai_profile_name'=>'Profile name','ai_system_prompt'=>'System prompt',
  'ai_category'=>'Category (empty = all)','ai_add_profile'=>'Add profile','ai_edit_profile'=>'Edit profile',
  'ai_model_hint'=>'Empty = provider default','ai_bad_url'=>'Invalid base URL. Use https (http is allowed only for localhost).',
  'ai_profile_bad'=>'Name, provider and system prompt are required.','ai_provider_exists'=>'A provider with this slug already exists.',
  'ai_key_hint'=>'Keys are stored encrypted with AES-256-GCM using app_key.',
  'ts_enabled'=>'Enabled on login and registration','ts_site_key'=>'Site key','ts_secret'=>'Secret key',
  'ts_secret_saved'=>'Secret saved (type a new one to replace)',
  'ts_hint'=>'If enabled without a secret key, login and registration are blocked.',
  'verify_user'=>'Verify user','verified'=>'Verified','assign_role'=>'Assign role','no_role'=>'No role',
  'assign'=>'Assign','create_role'=>'Create role','role_name'=>'Role name','power_level'=>'Power level',
  'role_hint'=>'Power level 50 and above grants moderator permissions. Custom roles cannot grant admin.',
  'roles_existing'=>'Existing roles','bulk_role'=>'Bulk set role','bulk_ids'=>'IDs: 1,2,3','set_role'=>'Set role',
  'status'=>'Status','category_tags'=>'Category tags','tags_placeholder'=>'design, guide, hobby',
  'tags_hint'=>'Tags appear as filters on the category page.','audit_when'=>'When','actor'=>'Actor','action'=>'Action',
  'notify_mentions'=>'Mentions','notify_replies'=>'Replies','notify_reactions'=>'Reactions','notify_digest'=>'Weekly digest',
  'bio_label'=>'Bio','theme_label'=>'Theme','accent_label'=>'Accent color',
  'ai_reply_fallback'=>'Reply',
];
PHP
  cat > "$APP_DIR/lang/tr.php" <<'PHP'
<?php return [
  'forum'=>'Forum','login'=>'Giriş Yap','register'=>'Kayıt Ol','logout'=>'Çıkış Yap',
  'username'=>'Kullanıcı adı','email'=>'E-posta','password'=>'Şifre','bio'=>'Hakkında',
  'categories'=>'Kategoriler','topics'=>'Konular','posts'=>'Mesajlar','views'=>'Görüntüleme',
  'new_topic'=>'Yeni Konu','reply'=>'Yanıtla','search'=>'Ara','submit'=>'Gönder',
  'notifications'=>'Bildirimler','mark_all_read'=>'Tümünü okundu işaretle','no_notifications'=>'Bildirim yok',
  'watch_topic'=>'Konuyu takip et','unwatch_topic'=>'Takibi bırak','topic_watch_on'=>'Konu takip ediliyor.','topic_watch_off'=>'Takip bırakıldı.',
  'theme'=>'Tema','accent'=>'Vurgu rengi','avatar_color'=>'Avatar rengi','settings'=>'Ayarlar','save'=>'Kaydet',
  'search_results'=>'Arama sonuçları','no_results'=>'Sonuç yok','search_placeholder'=>'Ara...',
  'home'=>'Ana Sayfa','activity'=>'Son Aktivite','stats'=>'İstatistikler','profile'=>'Profil',
  'recent_topics'=>'Son Konular','latest_posts'=>'Son Mesajlar','online_users'=>'Çevrimiçi',
  'members'=>'Üyeler','total_topics'=>'Konular','total_posts'=>'Mesajlar','total_users'=>'Üyeler',
  'joined'=>'Katılım','last_seen'=>'Son görülme','popular'=>'Popüler',
  'title'=>'Başlık','body'=>'İçerik','post_reply'=>'Gönder','back'=>'Geri','reply_to_topic'=>'Konuya yanıt ver',
  'all'=>'Tümü','tag_search'=>'Etiket ara...','tags_max'=>'Etiketler (en fazla 5)','image_upload'=>'Resim (jpg, png, gif, webp; en fazla 5 MB)',
  'title_body_required'=>'Başlık ve içerik gerekli.','post_too_fast'=>'Çok hızlı yazıyorsunuz. Biraz bekleyin.',
  'rate_wait'=>'Çok hızlı. Lütfen bir süre bekleyin.','verified_account'=>'Doğrulanmış hesap',
  'erendev_login'=>'ErenDev ile Giriş Yap','too_many_attempts'=>'Çok fazla deneme.','missing_info'=>'Eksik bilgi.',
  'bad_credentials'=>'E-posta veya şifre hatalı.','bot_detected'=>'Bot tespit edildi.',
  'register_limit'=>'Kayıt limiti aşıldı.','bad_username'=>'Kullanıcı adı 3-32 karakter olmalı.',
  'bad_email'=>'Geçerli e-posta girin.','weak_password'=>'Şifre en az 10 karakter olmalı.',
  'already_exists'=>'Zaten kayıtlı.','saved'=>'Kaydedildi.','not_found'=>'Bulunamadı.',
  'settings_saved'=>'Ayarlar kaydedildi.','site_name'=>'Site adı','site_tagline'=>'Site sloganı',
  'admin_settings'=>'Site ayarları','admin_panel'=>'Yönetim paneli',
  'tab_general'=>'Genel','tab_ai'=>'Yapay zeka asistanı','tab_turnstile'=>'Turnstile','tab_users'=>'Kullanıcılar ve roller',
  'tab_categories'=>'Kategoriler','tab_audit'=>'Denetim kaydı',
  'admin_audit'=>'Denetim kaydı','roles'=>'Roller','admin_users'=>'Kullanıcılar','admin_categories'=>'Kategori yönetimi',
  'add_category'=>'Kategori ekle','edit_category'=>'Kategoriyi düzenle','delete_category'=>'Kategoriyi sil',
  'delete_confirm'=>'Silmek istediğinizden emin misiniz?','yes_delete'=>'Evet, sil',
  'no_topics_yet'=>'Henüz konu yok.','loading'=>'Yükleniyor...','delete'=>'Sil','edit'=>'Düzenle',
  'slug'=>'Kısa ad (slug)','icon'=>'Simge','position'=>'Sıra','description'=>'Açıklama',
  'password_change'=>'Şifre değiştir','current_password'=>'Mevcut şifre',
  'new_password'=>'Yeni şifre','confirm_password'=>'Yeni şifre (tekrar)',
  'password_changed'=>'Şifre güncellendi.','password_mismatch'=>'Şifreler eşleşmiyor.',
  'password_wrong'=>'Mevcut şifre yanlış.',
  'forgot_password'=>'Şifremi unuttum','reset_password'=>'Şifreyi sıfırla',
  'reset_link_sent'=>'E-posta adresinize sıfırlama bağlantısı gönderildi (kayıtlıysa).',
  'reset_invalid'=>'Bağlantı geçersiz veya süresi dolmuş.','reset_complete'=>'Şifre sıfırlandı. Giriş yapabilirsiniz.',
  'pin'=>'Sabitle','unpin'=>'Sabitlemeyi kaldır','lock'=>'Kilitle','unlock'=>'Kilidi aç',
  'delete_post'=>'Mesajı sil','delete_topic'=>'Konuyu sil',
  'ban_user'=>'Kullanıcıyı yasakla','unban_user'=>'Yasağı kaldır','banned'=>'Yasaklandı',
  'mod_only'=>'Bu işlem için yetkiniz yok.',
  'edited'=>'düzenlendi','deleted_post'=>'[silindi]',
  'email_taken'=>'Bu e-posta kullanılıyor.','invalid_token'=>'Geçersiz token.',
  'banned_msg'=>'Hesabınız yasaklanmış.',
  'ai_enabled'=>'Etkin','ai_global'=>'Yapay zeka asistanı etkin','ai_hint'=>'Etkin her profil, bağlı olduğu sağlayıcıyla yanıt verir. Yanıtlar her dakika çalışan worker ile üretilir.',
  'ai_providers'=>'Sağlayıcılar','ai_profiles'=>'Profiller','ai_add_provider'=>'Özel sağlayıcı ekle',
  'ai_provider'=>'Sağlayıcı','ai_adapter'=>'Protokol','ai_base_url'=>'Temel adres','ai_model'=>'Model',
  'ai_default_model'=>'Varsayılan model','ai_api_key'=>'API anahtarı','ai_key_saved'=>'Anahtar kayıtlı (değiştirmek için yeni yazın)',
  'ai_no_key_needed'=>'Anahtar gerekmez','ai_profile_name'=>'Profil adı','ai_system_prompt'=>'Sistem promptu',
  'ai_category'=>'Kategori (boş = tümü)','ai_add_profile'=>'Profil ekle','ai_edit_profile'=>'Profili düzenle',
  'ai_model_hint'=>'Boş = sağlayıcının varsayılanı','ai_bad_url'=>'Geçersiz temel adres. https kullanın (http yalnızca localhost için).',
  'ai_profile_bad'=>'Ad, sağlayıcı ve sistem promptu zorunlu.','ai_provider_exists'=>'Bu kısa ada sahip bir sağlayıcı zaten var.',
  'ai_key_hint'=>'Anahtarlar app_key ile AES-256-GCM kullanılarak şifrelenip saklanır.',
  'ts_enabled'=>'Giriş ve kayıtta etkin','ts_site_key'=>'Site anahtarı','ts_secret'=>'Gizli anahtar',
  'ts_secret_saved'=>'Gizli anahtar kayıtlı (değiştirmek için yeni yazın)',
  'ts_hint'=>'Gizli anahtar tanımlı değilken etkinse giriş ve kayıt engellenir.',
  'verify_user'=>'Kullanıcıyı doğrula','verified'=>'Doğrulanmış','assign_role'=>'Rol ata','no_role'=>'Rol yok',
  'assign'=>'Ata','create_role'=>'Rol oluştur','role_name'=>'Rol adı','power_level'=>'Yetki seviyesi',
  'role_hint'=>'50 ve üzeri yetki seviyesi moderatör yetkisi verir. Özel roller yönetici yetkisi veremez.',
  'roles_existing'=>'Mevcut roller','bulk_role'=>'Toplu rol ata','bulk_ids'=>'ID: 1,2,3','set_role'=>'Rolü ayarla',
  'status'=>'Durum','category_tags'=>'Kategori etiketleri','tags_placeholder'=>'tasarım, rehber, hobi',
  'tags_hint'=>'Etiketler kategori sayfasında filtre olarak görünür.','audit_when'=>'Zaman','actor'=>'İşlemi yapan','action'=>'İşlem',
  'notify_mentions'=>'Bahsetmeler','notify_replies'=>'Yanıtlar','notify_reactions'=>'Tepkiler','notify_digest'=>'Haftalık özet',
  'bio_label'=>'Hakkında','theme_label'=>'Tema','accent_label'=>'Vurgu rengi',
  'ai_reply_fallback'=>'Yanıt',
];
PHP
  chown -R root:root "$APP_DIR/lang"
  find "$APP_DIR/lang" -type d -exec chmod 0755 {} \;
  find "$APP_DIR/lang" -type f -exec chmod 0644 {} \;
  ok "i18n (en and tr complete; others fall back to English)"
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
require LF_ROOT . '/app/settings.php';
require LF_ROOT . '/app/flash.php';
require LF_ROOT . '/app/markdown.php';
require LF_ROOT . '/app/avatar.php';
require LF_ROOT . '/app/activity.php';
require LF_ROOT . '/app/mail.php';
require LF_ROOT . '/app/crypto.php';
require LF_ROOT . '/app/turnstile.php';
require LF_ROOT . '/app/upload.php';
require LF_ROOT . '/app/tags.php';
require LF_ROOT . '/app/ai.php';
require LF_ROOT . '/app/admin-actions.php';

session_name($config['session_name']);
session_set_cookie_params([
  'lifetime' => 0, 'path' => '/',
  'secure'   => str_starts_with($config['base_url'], 'https://'),
  'httponly' => true, 'samesite' => 'Strict',
]);
session_start();

if (!isset($_SESSION['ui_lang']) || !in_array($_SESSION['ui_lang'], $config['available_langs'], true)) {
  $_SESSION['ui_lang'] = $config['default_lang'];
}
$GLOBALS['__config'] = $config;
$GLOBALS['__config_available_langs'] = $config['available_langs'];
i18n_init($_SESSION['ui_lang']);
csrf_init($config['app_key']);
$db = db_init($config['db_path']);
$GLOBALS['db'] = $db;
$GLOBALS['__app_name'] = settings_get($db, 'app_name', 'LiteForum');
$GLOBALS['__app_tagline'] = settings_get($db, 'app_tagline', '');
$GLOBALS['__turnstile_site'] = settings_get($db, 'turnstile_enabled', '0') === '1' ? settings_get($db, 'turnstile_site_key', '') : '';

if (!empty($_SESSION['user']['id'])) {
  $st = $db->prepare('SELECT u.banned, u.role, r.power_level AS role_power, r.name AS role_name, r.color_hex AS role_color
                      FROM users u LEFT JOIN roles r ON r.id = u.role_id WHERE u.id = ?');
  $st->execute([(int)$_SESSION['user']['id']]);
  $u = $st->fetch();
  if ($u && (int)$u['banned'] === 1) {
    $_SESSION['user'] = null;
    session_destroy();
    http_response_code(403);
    exit(t('banned_msg'));
  }
  if (!$u) {
    $_SESSION['user'] = null;
  } else {
    $_SESSION['user']['role']       = $u['role'];
    $_SESSION['user']['role_power'] = (int)($u['role_power'] ?? 0);
    $_SESSION['user']['role_name']  = $u['role_name'];
    $_SESSION['user']['role_color'] = $u['role_color'];
  }
}

if (PHP_SAPI !== 'cli') presence_touch($db);
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
  foreach (['journal_mode=WAL', 'busy_timeout=5000', 'synchronous=NORMAL', 'foreign_keys=ON', 'temp_store=MEMORY'] as $p) {
    $pdo->exec("PRAGMA $p;");
  }
  return $pdo;
}
PHP

  cat > "$APP_DIR/app/helpers.php" <<'PHP'
<?php
declare(strict_types=1);
function e(?string $s): string { return htmlspecialchars((string)$s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }
function redirect(string $to): never { header('Location: ' . $to, true, 302); exit; }
function rate_limit(PDO $db, string $bucket, string $ip, int $max, int $w): bool {
  $now = time();
  $db->prepare('DELETE FROM rate_limits WHERE ts < ?')->execute([$now - $w]);
  $st = $db->prepare('SELECT COUNT(*) FROM rate_limits WHERE bucket = ? AND ip = ? AND ts >= ?');
  $st->execute([$bucket, $ip, $now - $w]);
  if ((int)$st->fetchColumn() >= $max) return false;
  $db->prepare('INSERT INTO rate_limits(bucket, ip, ts) VALUES(?, ?, ?)')->execute([$bucket, $ip, $now]);
  return true;
}
function client_ip(): string {
  $remote = $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';
  $cf = $_SERVER['HTTP_CF_CONNECTING_IP'] ?? '';
  if (in_array($remote, ['127.0.0.1', '::1'], true) && is_string($cf) && filter_var($cf, FILTER_VALIDATE_IP)) return $cf;
  return $remote;
}
function safe_next(string $p): string {
  return (preg_match('#^/(?![/\\\\])#', $p) === 1 && !preg_match('/[\r\n]/', $p)) ? $p : '/';
}
function audit(PDO $db, ?array $actor, string $action, ?string $kind = null, ?int $id = null, array $meta = []): void {
  $db->prepare('INSERT INTO audit_log(actor_id, action, target_kind, target_id, meta, ip, ts) VALUES(?, ?, ?, ?, ?, ?, ?)')
     ->execute([$actor['id'] ?? null, $action, $kind, $id, json_encode($meta), client_ip(), time()]);
}
function time_ago(int $ts): string {
  $d = time() - $ts;
  if ($d < 60) return $d . 's';
  if ($d < 3600) return floor($d / 60) . 'm';
  if ($d < 86400) return floor($d / 3600) . 'h';
  if ($d < 2592000) return floor($d / 86400) . 'd';
  return date('Y-m-d', $ts);
}
function cat_name(array $cat, string $lc): string {
  return ($cat['name_' . $lc] ?? '') !== '' ? $cat['name_' . $lc] : ($cat['name_en'] ?? $cat['name_tr'] ?? '');
}
function cat_desc(array $cat, string $lc): string {
  return ($cat['description_' . $lc] ?? '') !== '' ? $cat['description_' . $lc] : ($cat['description_en'] ?? $cat['description_tr'] ?? '');
}
function is_mod(?array $u): bool {
  return $u !== null && (in_array($u['role'], ['moderator', 'admin'], true) || (int)($u['role_power'] ?? 0) >= 50);
}
function is_admin(?array $u): bool {
  return $u !== null && $u['role'] === 'admin';
}
function verified_badge(int $v): string {
  if (!$v) return '';
  $label = e(t('verified_account'));
  return '<svg class="verified" width="14" height="14" viewBox="0 0 24 24" role="img" aria-label="' . $label . '" style="vertical-align:-2px;margin-left:3px"><circle cx="12" cy="12" r="10" fill="var(--accent-500)"/><path d="M7 12.5l3 3 7-7" stroke="#fff" stroke-width="2.2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>';
}
PHP

  cat > "$APP_DIR/app/csrf.php" <<'PHP'
<?php
declare(strict_types=1);
function csrf_init(string $k): void { $_SESSION['csrf_token'] ??= bin2hex(random_bytes(32)); $_SESSION['csrf_key'] ??= $k; }
function csrf_token(): string { return $_SESSION['csrf_token']; }
function csrf_field(): string { return '<input type="hidden" name="_csrf" value="' . e(csrf_token()) . '">'; }
function csrf_verify(): void {
  $t = $_POST['_csrf'] ?? '';
  if (!is_string($t) || !hash_equals($_SESSION['csrf_token'] ?? '', $t)) { http_response_code(419); exit('Invalid CSRF token.'); }
}
PHP

  cat > "$APP_DIR/app/auth.php" <<'PHP'
<?php
declare(strict_types=1);
function auth_user(): ?array { return $_SESSION['user'] ?? null; }
function auth_require(): array {
  $u = auth_user();
  if (!$u) redirect('/login.php?next=' . urlencode($_SERVER['REQUEST_URI'] ?? '/'));
  return $u;
}
function auth_admin(): array {
  $u = auth_require();
  if (!is_admin($u)) { http_response_code(403); exit(t('mod_only')); }
  return $u;
}
function auth_mod(): array {
  $u = auth_require();
  if (!is_mod($u)) { http_response_code(403); exit(t('mod_only')); }
  return $u;
}
function auth_login(array $u): void {
  // Visitor was a guest until now: drop the guest presence row so they are counted once.
  $GLOBALS['db']->prepare('DELETE FROM presence WHERE pkey = ?')->execute([presence_guest_key()]);
  session_regenerate_id(true);
  $_SESSION['user'] = [
    'id'               => (int)$u['id'],
    'username'         => $u['username'],
    'role'             => $u['role'],
    'theme'            => $u['theme'] ?? 'dark',
    'accent'           => $u['accent'] ?? 'indigo',
    'bio'              => $u['bio'] ?? '',
    'avatar_color'     => $u['avatar_color'] ?? '#6366f1',
    'notify_mentions'  => (int)($u['notify_mentions'] ?? 1),
    'notify_replies'   => (int)($u['notify_replies'] ?? 1),
    'notify_reactions' => (int)($u['notify_reactions'] ?? 1),
    'notify_digest'    => (int)($u['notify_digest'] ?? 0),
  ];
  $GLOBALS['db']->prepare('UPDATE users SET last_login_at = ?, last_seen_at = ? WHERE id = ?')
                ->execute([time(), time(), (int)$u['id']]);
}
function auth_logout(): void {
  $_SESSION = [];
  if (ini_get('session.use_cookies')) {
    $p = session_get_cookie_params();
    setcookie(session_name(), '', time() - 42000, $p['path'], $p['domain'], $p['secure'], $p['httponly']);
  }
  session_destroy();
}
function password_hash_safe(string $p): string { return password_hash($p, PASSWORD_DEFAULT); }
function password_verify_safe(string $p, string $h): bool { return password_verify($p, $h); }
PHP

  cat > "$APP_DIR/app/i18n.php" <<'PHP'
<?php
declare(strict_types=1);
$GLOBALS['__lang'] = [];
function i18n_init(string $code): void {
  $avail = $GLOBALS['__config_available_langs'] ?? ['en'];
  $code = in_array($code, $avail, true) ? $code : 'en';
  $base = require LF_ROOT . '/lang/en.php';
  $over = [];
  if ($code !== 'en' && is_file(LF_ROOT . "/lang/$code.php")) {
    $over = require LF_ROOT . "/lang/$code.php";
  }
  $GLOBALS['__lang'] = $over + $base;
  $GLOBALS['__lang_code'] = $code;
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
    'indigo'  => ['500' => '#6366f1', '600' => '#4f46e5', '400' => '#818cf8', 'glow' => 'rgba(79,70,229,.25)'],
    'emerald' => ['500' => '#10b981', '600' => '#059669', '400' => '#34d399', 'glow' => 'rgba(16,185,129,.25)'],
    'rose'    => ['500' => '#f43f5e', '600' => '#e11d48', '400' => '#fb7185', 'glow' => 'rgba(244,63,94,.25)'],
    'amber'   => ['500' => '#f59e0b', '600' => '#d97706', '400' => '#fbbf24', 'glow' => 'rgba(245,158,11,.25)'],
    'sky'     => ['500' => '#0ea5e9', '600' => '#0284c7', '400' => '#38bdf8', 'glow' => 'rgba(14,165,233,.25)'],
  ];
  $c = $map[$accent] ?? $map['indigo'];
  if ($theme === 'light') {
    return "--bg:#f8fafc;--bg2:#f1f5f9;--fg:#0f172a;--fg-muted:#64748b;--panel:#ffffff;--panel2:#f8fafc;--border:#e2e8f0;--accent-500:{$c['500']};--accent-600:{$c['600']};--accent-400:{$c['400']};--glow:{$c['glow']};color-scheme:light;";
  }
  if ($theme === 'high-contrast') {
    return "--bg:#000000;--bg2:#0a0a0a;--fg:#ffffff;--fg-muted:#a3a3a3;--panel:#0a0a0a;--panel2:#111;--border:#404040;--accent-500:#ffff00;--accent-600:#ffff00;--accent-400:#ffff00;--glow:rgba(255,255,0,.15);color-scheme:dark;";
  }
  return "--bg:#020617;--bg2:#0a0f1e;--fg:#e2e8f0;--fg-muted:#94a3b8;--panel:rgba(15,23,42,.65);--panel2:rgba(30,41,59,.5);--border:#1e293b;--accent-500:{$c['500']};--accent-600:{$c['600']};--accent-400:{$c['400']};--glow:{$c['glow']};color-scheme:dark;";
}
PHP

  cat > "$APP_DIR/app/notifications.php" <<'PHP'
<?php
declare(strict_types=1);
function notif_create(PDO $db, int $userId, string $kind, ?int $topicId, ?int $postId, ?int $actorId, string $snippet): void {
  if ($userId === $actorId) return;
  $db->prepare('INSERT INTO notifications(user_id, kind, topic_id, post_id, actor_id, snippet, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)')
     ->execute([$userId, $kind, $topicId, $postId, $actorId, mb_substr($snippet, 0, 140), time()]);
}
function notif_for_mentions(PDO $db, string $body, int $topicId, int $postId, int $actorId): void {
  if (!preg_match_all('/@([A-Za-z0-9_\-]{3,32})/', $body, $m)) return;
  $st = $db->prepare('SELECT id, notify_mentions FROM users WHERE username = ?');
  foreach (array_unique($m[1]) as $uname) {
    $st->execute([$uname]);
    $row = $st->fetch();
    if ($row && (int)$row['notify_mentions'] === 1) notif_create($db, (int)$row['id'], 'mention', $topicId, $postId, $actorId, $body);
  }
}
function notif_for_replies(PDO $db, int $topicId, int $postId, int $actorId, string $body): void {
  $st = $db->prepare('SELECT w.user_id, u.notify_replies FROM topic_watches w JOIN users u ON u.id = w.user_id WHERE w.topic_id = ? AND w.user_id != ?');
  $st->execute([$topicId, $actorId]);
  foreach ($st->fetchAll() as $r) {
    if ((int)$r['notify_replies'] === 1) notif_create($db, (int)$r['user_id'], 'reply', $topicId, $postId, $actorId, $body);
  }
}
function notif_for_reaction(PDO $db, int $postId, int $actorId, string $emoji): void {
  $st = $db->prepare('SELECT p.user_id, u.notify_reactions, p.topic_id, p.body FROM posts p JOIN users u ON u.id = p.user_id WHERE p.id = ?');
  $st->execute([$postId]);
  $row = $st->fetch();
  if (!$row || (int)$row['user_id'] === $actorId || (int)$row['notify_reactions'] !== 1) return;
  notif_create($db, (int)$row['user_id'], 'reaction', (int)$row['topic_id'], $postId, $actorId, $emoji . ' ' . $row['body']);
}
function notif_unread_count(PDO $db, int $userId): int {
  $st = $db->prepare('SELECT COUNT(*) FROM notifications WHERE user_id = ? AND read_at IS NULL');
  $st->execute([$userId]);
  return (int)$st->fetchColumn();
}
function notif_list(PDO $db, int $userId, int $limit = 50): array {
  $st = $db->prepare('SELECT n.*, u.username AS actor FROM notifications n LEFT JOIN users u ON u.id = n.actor_id WHERE n.user_id = ? ORDER BY n.created_at DESC LIMIT ?');
  $st->execute([$userId, $limit]);
  return $st->fetchAll();
}
function notif_mark_all_read(PDO $db, int $userId): void {
  $db->prepare('UPDATE notifications SET read_at = ? WHERE user_id = ? AND read_at IS NULL')->execute([time(), $userId]);
}
PHP

  cat > "$APP_DIR/app/search.php" <<'PHP'
<?php
declare(strict_types=1);
function search_posts(PDO $db, string $q, ?int $categoryId = null, ?int $authorId = null, int $page = 1, int $per = 20): array {
  $q = trim($q);
  if ($q === '') return ['rows' => [], 'total' => 0];
  $where = ' WHERE posts_fts MATCH ? AND p.is_deleted = 0';
  $params = [$q];
  if ($categoryId) { $where .= ' AND t.category_id = ?'; $params[] = $categoryId; }
  if ($authorId)   { $where .= ' AND p.user_id = ?';     $params[] = $authorId; }
  $from = ' FROM posts_fts JOIN posts p ON p.id = posts_fts.rowid JOIN topics t ON t.id = p.topic_id JOIN users u ON u.id = p.user_id';
  $sql = 'SELECT p.id, p.topic_id, p.user_id, p.created_at,
                 snippet(posts_fts, 0, char(2), char(3), \'…\', 20) AS snippet,
                 bm25(posts_fts) AS rank, t.title AS topic_title, t.category_id, u.username'
         . $from . $where . ' ORDER BY rank LIMIT ? OFFSET ?';
  $st = $db->prepare($sql);
  try {
    $st->execute(array_merge($params, [$per, max(0, ($page - 1) * $per)]));
  } catch (PDOException) {
    return ['rows' => [], 'total' => 0];
  }
  $rows = $st->fetchAll();
  $cst = $db->prepare('SELECT COUNT(*)' . $from . $where);
  $cst->execute($params);
  return ['rows' => $rows, 'total' => (int)$cst->fetchColumn()];
}
PHP

  cat > "$APP_DIR/app/settings.php" <<'PHP'
<?php
declare(strict_types=1);
function settings_get(PDO $db, string $key, string $default = ''): string {
  static $cache = [];
  if (isset($cache[$key])) return $cache[$key];
  $st = $db->prepare('SELECT value FROM settings WHERE key = ?');
  $st->execute([$key]);
  $v = $st->fetchColumn();
  $cache[$key] = $v !== false ? (string)$v : $default;
  return $cache[$key];
}
function settings_set(PDO $db, string $key, string $value): void {
  $db->prepare('INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
     ->execute([$key, $value]);
}
PHP

  cat > "$APP_DIR/app/flash.php" <<'PHP'
<?php
declare(strict_types=1);
function flash_set(string $type, string $msg): void {
  $_SESSION['flash'] = ['type' => $type, 'msg' => $msg, 'ts' => time()];
}
function flash_get(): ?array {
  if (empty($_SESSION['flash'])) return null;
  $f = $_SESSION['flash'];
  unset($_SESSION['flash']);
  return (time() - $f['ts']) < 10 ? $f : null;
}
PHP

  cat > "$APP_DIR/app/markdown.php" <<'PHP'
<?php
declare(strict_types=1);
function render_post(string $body): string {
  $html = e($body);
  $html = preg_replace('/&gt; (.*)/u', '<blockquote style="border-left:3px solid var(--accent-500);padding-left:.75rem;color:var(--fg-muted);margin:.5rem 0">$1</blockquote>', $html);
  $html = preg_replace('/```([^`]+)```/us', '<pre style="background:var(--bg2);padding:.75rem;border-radius:.5rem;overflow-x:auto;font-family:ui-monospace,monospace;font-size:.85em">$1</pre>', $html);
  $html = preg_replace('/\*\*([^*]+)\*\*/u', '<strong>$1</strong>', $html);
  $html = preg_replace('/(?<!\*)\*([^*]+)\*(?!\*)/u', '<em>$1</em>', $html);
  $html = preg_replace('/`([^`]+)`/u', '<code style="background:var(--bg2);padding:1px 5px;border-radius:4px">$1</code>', $html);
  $html = preg_replace('/\[([^\]]+)\]\((https?:\/\/[^)]+)\)/u', '<a href="$2" rel="noopener nofollow" target="_blank">$1</a>', $html);
  $html = preg_replace('/@([A-Za-z0-9_\-]{3,32})/u', '<a href="/user.php?u=$1" style="background:var(--accent-500);color:#fff;padding:1px 6px;border-radius:4px;font-size:.85em">@$1</a>', $html);
  $html = preg_replace('/!\[([^\]]*)\]\((\/media\.php\?f=[a-f0-9]{32}\.(?:jpg|png|gif|webp))\)/u', '<img src="$2" alt="$1" loading="lazy" style="max-width:100%;border-radius:.5rem;display:block;margin:.5rem 0">', $html);
  return $html;
}
PHP

  cat > "$APP_DIR/app/avatar.php" <<'PHP'
<?php
declare(strict_types=1);
function user_avatar(string $username, string $color = '#6366f1', int $size = 32): string {
  $initial = mb_strtoupper(mb_substr($username, 0, 1));
  $c = e($color);
  $s = (int)$size;
  $f = (int)($s * 0.45);
  return "<span style=\"display:inline-flex;align-items:center;justify-content:center;width:{$s}px;height:{$s}px;border-radius:50%;background:linear-gradient(135deg,{$c},{$c}99);color:#fff;font-weight:700;font-size:{$f}px;flex-shrink:0\">" . e($initial) . "</span>";
}
PHP

  cat > "$APP_DIR/app/activity.php" <<'PHP'
<?php
declare(strict_types=1);
const ONLINE_WINDOW = 300; // seconds

/** Stable key for a guest, derived from the session id so the raw id is never stored. */
function presence_guest_key(): string {
  return 'g' . substr(hash('sha256', session_id()), 0, 40);
}

/** Records the current visitor (member or guest) as active. Called once per web request. */
function presence_touch(PDO $db): void {
  $uid = !empty($_SESSION['user']['id']) ? (int)$_SESSION['user']['id'] : null;
  $key = $uid ? 'u' . $uid : presence_guest_key();
  $now = time();
  $db->prepare('INSERT INTO presence(pkey, user_id, last_seen) VALUES(?, ?, ?)
                ON CONFLICT(pkey) DO UPDATE SET user_id = excluded.user_id, last_seen = excluded.last_seen')
     ->execute([$key, $uid, $now]);
  if ($uid) {
    $db->prepare('UPDATE users SET last_seen_at = ? WHERE id = ? AND (last_seen_at IS NULL OR last_seen_at < ?)')
       ->execute([$now, $uid, $now - 60]);
  }
  if (random_int(1, 100) === 1) {
    $db->prepare('DELETE FROM presence WHERE last_seen < ?')->execute([$now - 86400]);
  }
}
/** Everyone (members and guests) active in the last ONLINE_WINDOW seconds. */
function online_count(PDO $db): int {
  $st = $db->prepare('SELECT COUNT(*) FROM presence WHERE last_seen > ?');
  $st->execute([time() - ONLINE_WINDOW]);
  return (int)$st->fetchColumn();
}
/** Registered members active in the last ONLINE_WINDOW seconds. */
function online_members_count(PDO $db): int {
  $st = $db->prepare('SELECT COUNT(*) FROM presence WHERE last_seen > ? AND user_id IS NOT NULL');
  $st->execute([time() - ONLINE_WINDOW]);
  return (int)$st->fetchColumn();
}
function recent_topics(PDO $db, int $limit = 10): array {
  $st = $db->prepare('SELECT t.*, u.username, c.slug AS cat_slug,
    (SELECT COUNT(*) FROM posts p WHERE p.topic_id = t.id AND p.is_deleted = 0) AS post_count
    FROM topics t JOIN users u ON u.id = t.user_id JOIN categories c ON c.id = t.category_id
    ORDER BY t.updated_at DESC LIMIT ?');
  $st->execute([$limit]);
  return $st->fetchAll();
}
function recent_posts(PDO $db, int $limit = 10): array {
  $st = $db->prepare('SELECT p.*, u.username, t.title AS topic_title, t.id AS topic_id
    FROM posts p JOIN users u ON u.id = p.user_id JOIN topics t ON t.id = p.topic_id
    WHERE p.is_deleted = 0 ORDER BY p.created_at DESC LIMIT ?');
  $st->execute([$limit]);
  return $st->fetchAll();
}
function forum_stats(PDO $db): array {
  return [
    'topics'  => (int)$db->query('SELECT COUNT(*) FROM topics')->fetchColumn(),
    'posts'   => (int)$db->query('SELECT COUNT(*) FROM posts WHERE is_deleted = 0')->fetchColumn(),
    'users'   => (int)$db->query('SELECT COUNT(*) FROM users')->fetchColumn(),
    'online'  => online_count($db),
    'members_online' => online_members_count($db),
    'newest'  => $db->query('SELECT username, created_at FROM users ORDER BY id DESC LIMIT 1')->fetch() ?: null,
  ];
}
PHP

  cat > "$APP_DIR/app/mail.php" <<'PHP'
<?php
declare(strict_types=1);
function send_mail(string $to, string $subject, string $body): bool {
  $from = $GLOBALS['__config']['admin_email'] ?? 'noreply@localhost';
  $headers  = "From: LiteForum <$from>\r\n";
  $headers .= "Content-Type: text/plain; charset=UTF-8\r\n";
  $headers .= "MIME-Version: 1.0\r\n";
  return @mail($to, $subject, $body, $headers);
}
function generate_reset_token(PDO $db, int $userId): string {
  $token = bin2hex(random_bytes(32));
  $db->prepare('DELETE FROM password_resets WHERE user_id = ?')->execute([$userId]);
  $db->prepare('INSERT INTO password_resets(token, user_id, expires_at) VALUES(?, ?, ?)')
     ->execute([hash('sha256', $token), $userId, time() + 3600]);
  return $token;
}
function consume_reset_token(PDO $db, string $token): ?int {
  $st = $db->prepare('SELECT user_id FROM password_resets WHERE token = ? AND expires_at > ? AND used = 0');
  $st->execute([hash('sha256', $token), time()]);
  $row = $st->fetch();
  if (!$row) return null;
  $db->prepare('UPDATE password_resets SET used = 1 WHERE token = ?')->execute([hash('sha256', $token)]);
  return (int)$row['user_id'];
}
PHP

  cat > "$APP_DIR/app/crypto.php" <<'PHP'
<?php
declare(strict_types=1);
function secret_key(string $appKey): string { return hash('sha256', $appKey, true); }
function secret_encrypt(string $plain, string $appKey): string {
  $iv = random_bytes(12);
  $tag = '';
  $ct = openssl_encrypt($plain, 'aes-256-gcm', secret_key($appKey), OPENSSL_RAW_DATA, $iv, $tag, '', 16);
  if ($ct === false) throw new RuntimeException('encrypt failed');
  return 'v1:' . base64_encode($iv . $tag . $ct);
}
function secret_decrypt(string $stored, string $appKey): ?string {
  if (!str_starts_with($stored, 'v1:')) return null;
  $raw = base64_decode(substr($stored, 3), true);
  if ($raw === false || strlen($raw) < 29) return null;
  $iv  = substr($raw, 0, 12);
  $tag = substr($raw, 12, 16);
  $ct  = substr($raw, 28);
  $pt = openssl_decrypt($ct, 'aes-256-gcm', secret_key($appKey), OPENSSL_RAW_DATA, $iv, $tag);
  return $pt === false ? null : $pt;
}
PHP

  cat > "$APP_DIR/app/turnstile.php" <<'PHP'
<?php
declare(strict_types=1);
function turnstile_verify(string $secret, string $token, string $ip = ''): bool {
  if ($secret === '' || $token === '') return false;
  $ch = curl_init('https://challenges.cloudflare.com/turnstile/v0/siteverify');
  curl_setopt_array($ch, [
    CURLOPT_POST => true,
    CURLOPT_POSTFIELDS => ['secret' => $secret, 'response' => $token, 'remoteip' => $ip],
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_TIMEOUT => 5,
    CURLOPT_SSL_VERIFYPEER => true,
  ]);
  $res = curl_exec($ch);
  curl_close($ch);
  if (!is_string($res)) return false;
  $j = json_decode($res, true);
  return is_array($j) && ($j['success'] ?? false) === true;
}
function turnstile_ok(PDO $db, array $config): bool {
  if (settings_get($db, 'turnstile_enabled', '0') !== '1') return true;
  $secret = secret_decrypt(settings_get($db, 'turnstile_secret_enc', ''), $config['app_key']) ?? '';
  return turnstile_verify($secret, (string)($_POST['cf-turnstile-response'] ?? ''), client_ip());
}
PHP

  cat > "$APP_DIR/app/upload.php" <<'PHP'
<?php
declare(strict_types=1);
const UPLOAD_MAX_BYTES = 5 * 1024 * 1024;
const UPLOAD_ALLOWED = [
  'image/jpeg' => 'jpg',
  'image/png'  => 'png',
  'image/gif'  => 'gif',
  'image/webp' => 'webp',
];
function upload_dir(): string { return dirname($GLOBALS['__config']['db_path']) . '/uploads'; }
function secure_uploaded_file(array $file, string $destDir): array {
  if (!isset($file['error']) || is_array($file['error'])) throw new RuntimeException(t('invalid_token'));
  if ($file['error'] !== UPLOAD_ERR_OK) throw new RuntimeException(t('not_found'));
  if (!is_uploaded_file($file['tmp_name'])) throw new RuntimeException(t('invalid_token'));
  if ($file['size'] <= 0 || $file['size'] > UPLOAD_MAX_BYTES) throw new RuntimeException(t('image_upload'));
  $mime = (new finfo(FILEINFO_MIME_TYPE))->file($file['tmp_name']) ?: '';
  if (!isset(UPLOAD_ALLOWED[$mime])) throw new RuntimeException(t('image_upload'));
  if (@getimagesize($file['tmp_name']) === false) throw new RuntimeException(t('image_upload'));
  $name = bin2hex(random_bytes(16)) . '.' . UPLOAD_ALLOWED[$mime];
  $dest = rtrim($destDir, '/') . '/' . $name;
  if (!move_uploaded_file($file['tmp_name'], $dest)) throw new RuntimeException(t('saved'));
  chmod($dest, 0640);
  return [$name, $mime, (int)$file['size']];
}
function append_upload(PDO $db, string $body, int $userId): string {
  if (!isset($_FILES['image']) || ($_FILES['image']['error'] ?? UPLOAD_ERR_NO_FILE) === UPLOAD_ERR_NO_FILE) return $body;
  [$name, $mime, $size] = secure_uploaded_file($_FILES['image'], upload_dir());
  $db->prepare('INSERT INTO uploads(user_id, post_id, stored_name, original_name, mime, size, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)')
     ->execute([$userId, null, $name, mb_substr(basename((string)$_FILES['image']['name']), 0, 120), $mime, $size, time()]);
  return rtrim($body) . "\n\n![image](/media.php?f=" . $name . ")";
}
PHP

  cat > "$APP_DIR/app/tags.php" <<'PHP'
<?php
declare(strict_types=1);
function tag_slugify(string $name): string {
  $s = preg_replace('/[^\p{L}\p{N}]+/u', '-', mb_strtolower($name));
  return trim((string)$s, '-');
}
function tag_get_or_create(PDO $db, string $name): int {
  $slug = tag_slugify($name);
  if ($slug === '') return 0;
  $db->prepare('INSERT OR IGNORE INTO tags(name, slug) VALUES(?, ?)')->execute([$name, $slug]);
  $st = $db->prepare('SELECT id FROM tags WHERE slug = ?');
  $st->execute([$slug]);
  return (int)$st->fetchColumn();
}
function tags_save(PDO $db, int $topicId, int $catId, array $submitted): void {
  $st = $db->prepare('SELECT tag_id FROM category_tags WHERE category_id = ?');
  $st->execute([$catId]);
  $allowed = array_map('intval', array_column($st->fetchAll(), 'tag_id'));
  $ins = $db->prepare('INSERT OR IGNORE INTO topic_tags(topic_id, tag_id) VALUES(?, ?)');
  $ids = array_slice(array_unique(array_map('intval', $submitted)), 0, 5);
  foreach ($ids as $tid) {
    if (in_array($tid, $allowed, true)) $ins->execute([$topicId, $tid]);
  }
}
function tags_for_topics(PDO $db, array $ids): array {
  $out = [];
  if (!$ids) return $out;
  $ph = implode(',', array_fill(0, count($ids), '?'));
  $st = $db->prepare("SELECT tt.topic_id, g.name, g.slug FROM topic_tags tt JOIN tags g ON g.id = tt.tag_id WHERE tt.topic_id IN ($ph) ORDER BY g.name");
  $st->execute(array_values($ids));
  foreach ($st->fetchAll() as $r) $out[(int)$r['topic_id']][] = ['name' => $r['name'], 'slug' => $r['slug']];
  return $out;
}
function tag_search(PDO $db, string $q): array {
  $clean = trim((string)preg_replace('/[^\p{L}\p{N}\s]+/u', ' ', $q));
  $terms = preg_split('/\s+/u', $clean, -1, PREG_SPLIT_NO_EMPTY);
  if (!$terms) return [];
  $match = implode(' ', array_map(fn($t) => '"' . $t . '"*', array_slice($terms, 0, 5)));
  try {
    $st = $db->prepare('SELECT g.name, g.slug FROM tags_fts f JOIN tags g ON g.id = f.rowid WHERE tags_fts MATCH ? ORDER BY bm25(tags_fts) LIMIT 20');
    $st->execute([$match]);
    return $st->fetchAll();
  } catch (PDOException) {
    return [];
  }
}
PHP

  cat > "$APP_DIR/app/ai.php" <<'PHP'
<?php
declare(strict_types=1);
/*
 * AI adapters. Each provider speaks its own protocol; each protocol has its own function below.
 * To add a provider that speaks an existing protocol, insert a row in ai_providers (admin panel).
 * To add a new protocol, write ai_<name>() here, add it to ai_adapters() and to ai_call().
 */
const AI_SAFETY_SUFFIX = ' Return only the reply text. Do not produce harmful, misleading, or personal-data-seeking content. Reply in the language of the topic.';
const AI_MAX_TOKENS = 800;

function ai_adapters(): array {
  return [
    'anthropic'     => 'Anthropic Messages',
    'openai'        => 'OpenAI Chat Completions',
    'gemini'        => 'Google Gemini generateContent',
    'groq'          => 'Groq Chat Completions',
    'openrouter'    => 'OpenRouter Chat Completions',
    'mistral'       => 'Mistral Chat Completions',
    'together'      => 'Together AI Chat Completions',
    'deepseek'      => 'DeepSeek Chat Completions',
    'cohere'        => 'Cohere Chat v2',
    'ollama'        => 'Ollama Chat (local)',
    'openai_compat' => 'Custom OpenAI-compatible',
  ];
}

/** Validates an admin-supplied base URL. https is required, http only for localhost. */
function ai_valid_base(string $url): string {
  $url = rtrim(trim($url), '/');
  $p = $url === '' ? false : parse_url($url);
  if (!$p || empty($p['scheme']) || empty($p['host']) || isset($p['user']) || isset($p['pass'])) {
    throw new RuntimeException(t('ai_bad_url'));
  }
  $local = in_array($p['host'], ['127.0.0.1', 'localhost'], true);
  if ($p['scheme'] !== 'https' && !($p['scheme'] === 'http' && $local)) {
    throw new RuntimeException(t('ai_bad_url'));
  }
  return $url;
}

/** POSTs JSON, returns decoded array or throws with a short, key-free error. */
function ai_http(string $url, array $headers, array $body, int $timeout = 90): array {
  $ch = curl_init($url);
  curl_setopt_array($ch, [
    CURLOPT_POST => true,
    CURLOPT_POSTFIELDS => json_encode($body, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR),
    CURLOPT_HTTPHEADER => array_merge(['Content-Type: application/json', 'Accept: application/json'], $headers),
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_TIMEOUT => $timeout,
    CURLOPT_SSL_VERIFYPEER => true,
  ]);
  $res = curl_exec($ch);
  $code = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
  $err = curl_error($ch);
  curl_close($ch);
  if (!is_string($res)) throw new RuntimeException('Transport error: ' . mb_substr($err, 0, 120));
  $j = json_decode($res, true);
  if ($code < 200 || $code >= 300) {
    $hint = is_array($j) ? mb_substr((string)json_encode($j, JSON_UNESCAPED_UNICODE), 0, 160) : '';
    throw new RuntimeException("HTTP $code $hint");
  }
  if (!is_array($j)) throw new RuntimeException('Invalid JSON from provider');
  return $j;
}

function ai_text(?string $t): string {
  $t = trim((string)$t);
  if ($t === '') throw new RuntimeException('Empty reply from provider');
  return mb_substr($t, 0, 8000);
}

/* ---------- Protocol: Anthropic Messages ---------- */
function ai_anthropic(string $base, string $key, string $model, string $system, string $user): string {
  $j = ai_http($base . '/v1/messages',
    ['x-api-key: ' . $key, 'anthropic-version: 2023-06-01'],
    ['model' => $model, 'max_tokens' => AI_MAX_TOKENS, 'system' => $system,
     'messages' => [['role' => 'user', 'content' => $user]]]);
  $parts = array_filter($j['content'] ?? [], fn($c) => ($c['type'] ?? '') === 'text');
  return ai_text(implode('', array_column($parts, 'text')));
}

/* ---------- Protocol: OpenAI Chat Completions ---------- */
function ai_openai(string $base, string $key, string $model, string $system, string $user): string {
  $j = ai_http($base . '/chat/completions',
    ['Authorization: Bearer ' . $key],
    ['model' => $model, 'max_tokens' => AI_MAX_TOKENS,
     'messages' => [['role' => 'system', 'content' => $system], ['role' => 'user', 'content' => $user]]]);
  return ai_text($j['choices'][0]['message']['content'] ?? null);
}

/* ---------- Protocol: Google Gemini generateContent (native) ---------- */
function ai_gemini(string $base, string $key, string $model, string $system, string $user): string {
  $j = ai_http($base . '/models/' . rawurlencode($model) . ':generateContent',
    ['x-goog-api-key: ' . $key],
    ['system_instruction' => ['parts' => [['text' => $system]]],
     'contents' => [['role' => 'user', 'parts' => [['text' => $user]]]],
     'generationConfig' => ['maxOutputTokens' => 1024]]);
  $parts = $j['candidates'][0]['content']['parts'] ?? [];
  return ai_text(implode('', array_map(fn($p) => (string)($p['text'] ?? ''), $parts)));
}

/* ---------- Protocol: Groq (OpenAI-style request, Groq endpoint and headers) ---------- */
function ai_groq(string $base, string $key, string $model, string $system, string $user): string {
  $j = ai_http($base . '/chat/completions',
    ['Authorization: Bearer ' . $key],
    ['model' => $model, 'max_tokens' => AI_MAX_TOKENS, 'temperature' => 0.7,
     'messages' => [['role' => 'system', 'content' => $system], ['role' => 'user', 'content' => $user]]]);
  return ai_text($j['choices'][0]['message']['content'] ?? null);
}

/* ---------- Protocol: OpenRouter (OpenAI-style, plus app attribution headers) ---------- */
function ai_openrouter(string $base, string $key, string $model, string $system, string $user): string {
  $site = $GLOBALS['__config']['base_url'] ?? 'https://localhost';
  $j = ai_http($base . '/chat/completions',
    ['Authorization: Bearer ' . $key, 'HTTP-Referer: ' . $site, 'X-Title: LiteForum'],
    ['model' => $model, 'max_tokens' => AI_MAX_TOKENS,
     'messages' => [['role' => 'system', 'content' => $system], ['role' => 'user', 'content' => $user]]]);
  return ai_text($j['choices'][0]['message']['content'] ?? null);
}

/* ---------- Protocol: Mistral (OpenAI-style, own endpoint) ---------- */
function ai_mistral(string $base, string $key, string $model, string $system, string $user): string {
  $j = ai_http($base . '/chat/completions',
    ['Authorization: Bearer ' . $key],
    ['model' => $model, 'max_tokens' => AI_MAX_TOKENS,
     'messages' => [['role' => 'system', 'content' => $system], ['role' => 'user', 'content' => $user]]]);
  return ai_text($j['choices'][0]['message']['content'] ?? null);
}

/* ---------- Protocol: Together AI (OpenAI-style, own endpoint) ---------- */
function ai_together(string $base, string $key, string $model, string $system, string $user): string {
  $j = ai_http($base . '/chat/completions',
    ['Authorization: Bearer ' . $key],
    ['model' => $model, 'max_tokens' => AI_MAX_TOKENS,
     'messages' => [['role' => 'system', 'content' => $system], ['role' => 'user', 'content' => $user]]]);
  return ai_text($j['choices'][0]['message']['content'] ?? null);
}

/* ---------- Protocol: DeepSeek (OpenAI-style, own endpoint) ---------- */
function ai_deepseek(string $base, string $key, string $model, string $system, string $user): string {
  $j = ai_http($base . '/chat/completions',
    ['Authorization: Bearer ' . $key],
    ['model' => $model, 'max_tokens' => AI_MAX_TOKENS, 'stream' => false,
     'messages' => [['role' => 'system', 'content' => $system], ['role' => 'user', 'content' => $user]]]);
  return ai_text($j['choices'][0]['message']['content'] ?? null);
}

/* ---------- Protocol: Cohere Chat v2 ---------- */
function ai_cohere(string $base, string $key, string $model, string $system, string $user): string {
  $j = ai_http($base . '/v2/chat',
    ['Authorization: Bearer ' . $key],
    ['model' => $model, 'max_tokens' => AI_MAX_TOKENS,
     'messages' => [['role' => 'system', 'content' => $system], ['role' => 'user', 'content' => $user]]]);
  $parts = array_filter($j['message']['content'] ?? [], fn($c) => ($c['type'] ?? '') === 'text');
  return ai_text(implode('', array_column($parts, 'text')));
}

/* ---------- Protocol: Ollama Chat (local, no key) ---------- */
function ai_ollama(string $base, string $key, string $model, string $system, string $user): string {
  $headers = $key !== '' ? ['Authorization: Bearer ' . $key] : [];
  $j = ai_http($base . '/api/chat', $headers,
    ['model' => $model, 'stream' => false,
     'messages' => [['role' => 'system', 'content' => $system], ['role' => 'user', 'content' => $user]]]);
  return ai_text($j['message']['content'] ?? null);
}

/* ---------- Protocol: Custom OpenAI-compatible endpoint (admin supplies base URL) ---------- */
function ai_openai_compat(string $base, string $key, string $model, string $system, string $user): string {
  $headers = $key !== '' ? ['Authorization: Bearer ' . $key] : [];
  $j = ai_http($base . '/chat/completions', $headers,
    ['model' => $model, 'max_tokens' => AI_MAX_TOKENS,
     'messages' => [['role' => 'system', 'content' => $system], ['role' => 'user', 'content' => $user]]]);
  return ai_text($j['choices'][0]['message']['content'] ?? null);
}

/** Dispatches to the protocol function for the provider's adapter. */
function ai_call(string $adapter, string $base, string $key, string $model, string $system, string $user): string {
  $b = rtrim($base, '/');
  return match ($adapter) {
    'anthropic'     => ai_anthropic($b, $key, $model, $system, $user),
    'openai'        => ai_openai($b, $key, $model, $system, $user),
    'gemini'        => ai_gemini($b, $key, $model, $system, $user),
    'groq'          => ai_groq($b, $key, $model, $system, $user),
    'openrouter'    => ai_openrouter($b, $key, $model, $system, $user),
    'mistral'       => ai_mistral($b, $key, $model, $system, $user),
    'together'      => ai_together($b, $key, $model, $system, $user),
    'deepseek'      => ai_deepseek($b, $key, $model, $system, $user),
    'cohere'        => ai_cohere($b, $key, $model, $system, $user),
    'ollama'        => ai_ollama($b, $key, $model, $system, $user),
    'openai_compat' => ai_openai_compat($b, $key, $model, $system, $user),
    default         => throw new RuntimeException('Unknown adapter: ' . $adapter),
  };
}

/** Builds the topic context shown to the model. */
function ai_context(PDO $db, int $topicId): string {
  $t = $db->prepare('SELECT title FROM topics WHERE id = ?');
  $t->execute([$topicId]);
  $title = (string)$t->fetchColumn();
  $p = $db->prepare('SELECT u.username, p.body FROM posts p JOIN users u ON u.id = p.user_id
                     WHERE p.topic_id = ? AND p.is_deleted = 0 ORDER BY p.created_at DESC LIMIT 8');
  $p->execute([$topicId]);
  $out = "Topic title: $title\n\nRecent posts:\n";
  foreach (array_reverse($p->fetchAll()) as $r) {
    $out .= '@' . $r['username'] . ': ' . mb_substr((string)$r['body'], 0, 1200) . "\n\n";
  }
  return $out;
}

/**
 * Queues one reply for a new post. Picks the first enabled profile whose category matches
 * (category-specific profiles first, then profiles for all categories).
 */
function ai_enqueue(PDO $db, int $topicId, int $postId, int $authorId, ?int $categoryId): void {
  if (settings_get($db, 'ai_enabled', '0') !== '1') return;
  $isBot = $db->prepare('SELECT 1 FROM ai_profiles WHERE user_id = ?');
  $isBot->execute([$authorId]);
  if ($isBot->fetchColumn()) return;
  $st = $db->prepare('SELECT p.id FROM ai_profiles p JOIN ai_providers pr ON pr.id = p.provider_id
                      WHERE p.enabled = 1 AND pr.enabled = 1 AND (p.category_id IS NULL OR p.category_id = ?)
                      ORDER BY (p.category_id IS NULL) ASC, p.id ASC LIMIT 1');
  $st->execute([$categoryId ?? 0]);
  $profileId = (int)$st->fetchColumn();
  if ($profileId <= 0) return;
  $db->prepare("INSERT INTO ai_jobs(topic_id, post_id, profile_id, status, created_at, updated_at) VALUES(?, ?, ?, 'queued', ?, ?)")
     ->execute([$topicId, $postId, $profileId, time(), time()]);
}

/** Processes up to $limit queued jobs. Called by the cron worker every minute. */
function ai_run_jobs(PDO $db, array $config, int $limit = 5): int {
  if (settings_get($db, 'ai_enabled', '0') !== '1') return 0;
  $st = $db->prepare("SELECT j.id, j.topic_id, p.system_prompt, p.model AS profile_model, p.user_id,
                             pr.adapter, pr.base_url, pr.default_model, pr.api_key_enc
                      FROM ai_jobs j
                      JOIN ai_profiles p ON p.id = j.profile_id
                      JOIN ai_providers pr ON pr.id = p.provider_id
                      WHERE j.status = 'queued' AND p.enabled = 1 AND pr.enabled = 1
                      ORDER BY j.id LIMIT ?");
  $st->bindValue(1, $limit, PDO::PARAM_INT);
  $st->execute();
  $jobs = $st->fetchAll();
  $done = 0;
  foreach ($jobs as $j) {
    $jid = (int)$j['id'];
    $db->prepare("UPDATE ai_jobs SET status = 'running', updated_at = ? WHERE id = ?")->execute([time(), $jid]);
    try {
      $key = secret_decrypt((string)$j['api_key_enc'], $config['app_key']) ?? '';
      if ($key === '' && !in_array($j['adapter'], ['ollama', 'openai_compat'], true)) {
        throw new RuntimeException('API key not set for this provider');
      }
      $model = trim((string)$j['profile_model']) !== '' ? (string)$j['profile_model'] : (string)$j['default_model'];
      $reply = ai_call(
        (string)$j['adapter'], (string)$j['base_url'], $key, $model,
        trim((string)$j['system_prompt']) . AI_SAFETY_SUFFIX,
        ai_context($db, (int)$j['topic_id'])
      );
      $db->prepare('INSERT INTO posts(topic_id, user_id, body, created_at, updated_at) VALUES(?, ?, ?, ?, ?)')
         ->execute([(int)$j['topic_id'], (int)$j['user_id'], $reply, time(), time()]);
      $db->prepare('UPDATE topics SET updated_at = ? WHERE id = ?')->execute([time(), (int)$j['topic_id']]);
      $db->prepare("UPDATE ai_jobs SET status = 'done', updated_at = ? WHERE id = ?")->execute([time(), $jid]);
      $done++;
    } catch (Throwable $ex) {
      $db->prepare("UPDATE ai_jobs SET status = 'failed', error = ?, updated_at = ? WHERE id = ?")
         ->execute([mb_substr($ex->getMessage(), 0, 300), time(), $jid]);
    }
  }
  return $done;
}
PHP

  cat > "$APP_DIR/app/admin-actions.php" <<'PHP'
<?php
declare(strict_types=1);
function admin_user_id(PDO $db, string $username): int {
  $st = $db->prepare('SELECT id FROM users WHERE username = ?');
  $st->execute([trim($username)]);
  return (int)$st->fetchColumn();
}

/** Handles tab-scoped actions. Returns true when the action was recognised. */
function admin_extra_action(PDO $db, array $u, array $config, string $action): bool {
  switch ($action) {

    case 'save_ai_global':
      settings_set($db, 'ai_enabled', isset($_POST['ai_enabled']) ? '1' : '0');
      audit($db, $u, 'ai.global', null, null, ['enabled' => isset($_POST['ai_enabled'])]);
      flash_set('ok', t('settings_saved'));
      return true;

    case 'save_provider':
      $id = (int)($_POST['provider_id'] ?? 0);
      $st = $db->prepare('SELECT * FROM ai_providers WHERE id = ?');
      $st->execute([$id]);
      $pv = $st->fetch();
      if (!$pv) { flash_set('err', t('not_found')); return true; }
      try {
        $base = ai_valid_base((string)($_POST['base_url'] ?? $pv['base_url']));
      } catch (RuntimeException $ex) {
        flash_set('err', $ex->getMessage());
        return true;
      }
      $model = mb_substr(trim((string)($_POST['default_model'] ?? '')), 0, 100);
      $db->prepare('UPDATE ai_providers SET base_url = ?, default_model = ?, enabled = ? WHERE id = ?')
         ->execute([$base, $model, isset($_POST['enabled']) ? 1 : 0, $id]);
      $key = trim((string)($_POST['api_key'] ?? ''));
      if ($key !== '') {
        $db->prepare('UPDATE ai_providers SET api_key_enc = ? WHERE id = ?')
           ->execute([secret_encrypt($key, $config['app_key']), $id]);
      }
      audit($db, $u, 'ai.provider_update', 'ai_provider', $id);
      flash_set('ok', t('saved'));
      return true;

    case 'add_provider':
      $name    = mb_substr(trim((string)($_POST['name'] ?? '')), 0, 60);
      $slug    = strtolower(preg_replace('/[^a-z0-9\-]/i', '', (string)($_POST['slug'] ?? '')));
      $adapter = (string)($_POST['adapter'] ?? '');
      $model   = mb_substr(trim((string)($_POST['default_model'] ?? '')), 0, 100);
      if ($name === '' || strlen($slug) < 2 || !array_key_exists($adapter, ai_adapters())) {
        flash_set('err', t('ai_profile_bad'));
        return true;
      }
      try {
        $base = ai_valid_base((string)($_POST['base_url'] ?? ''));
      } catch (RuntimeException $ex) {
        flash_set('err', $ex->getMessage());
        return true;
      }
      try {
        $db->prepare('INSERT INTO ai_providers(slug, name, adapter, base_url, default_model, enabled, builtin) VALUES(?, ?, ?, ?, ?, 1, 0)')
           ->execute([$slug, $name, $adapter, $base, $model]);
        audit($db, $u, 'ai.provider_add', 'ai_provider', (int)$db->lastInsertId());
        flash_set('ok', t('saved'));
      } catch (PDOException) {
        flash_set('err', t('ai_provider_exists'));
      }
      return true;

    case 'save_profile':
      $id      = (int)($_POST['profile_id'] ?? 0);
      $name    = mb_substr(trim((string)($_POST['name'] ?? '')), 0, 60);
      $provId  = (int)($_POST['provider_id'] ?? 0);
      $model   = mb_substr(trim((string)($_POST['model'] ?? '')), 0, 100);
      $prompt  = mb_substr(trim((string)($_POST['system_prompt'] ?? '')), 0, 4000);
      $catRaw  = (string)($_POST['category_id'] ?? '');
      $catId   = ctype_digit($catRaw) && (int)$catRaw > 0 ? (int)$catRaw : null;
      $enabled = isset($_POST['enabled']) ? 1 : 0;
      if ($name === '' || $prompt === '' || $provId <= 0) {
        flash_set('err', t('ai_profile_bad'));
        return true;
      }
      $chk = $db->prepare('SELECT 1 FROM ai_providers WHERE id = ?');
      $chk->execute([$provId]);
      if (!$chk->fetchColumn()) { flash_set('err', t('not_found')); return true; }
      try {
        if ($id > 0) {
          $db->prepare('UPDATE ai_profiles SET name = ?, provider_id = ?, model = ?, system_prompt = ?, category_id = ?, enabled = ? WHERE id = ?')
             ->execute([$name, $provId, $model, $prompt, $catId, $enabled, $id]);
          audit($db, $u, 'ai.profile_update', 'ai_profile', $id);
        } else {
          // Each profile posts as its own bot account, so replies show who wrote them.
          $suffix = bin2hex(random_bytes(3));
          $handle = substr((string)preg_replace('/[^A-Za-z0-9]+/', '_', $name), 0, 20);
          $handle = ($handle !== '' ? $handle : 'ai') . '_' . $suffix;
          $db->prepare('INSERT INTO users(username, email, password_hash, role, created_at, last_seen_at, is_verified) VALUES(?, ?, ?, ?, ?, ?, 1)')
             ->execute([$handle, 'ai+' . $suffix . '@liteforum.invalid', '!', 'member', time(), time()]);
          $uid = (int)$db->lastInsertId();
          $db->prepare('INSERT INTO ai_profiles(name, provider_id, model, system_prompt, category_id, user_id, enabled, created_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?)')
             ->execute([$name, $provId, $model, $prompt, $catId, $uid, $enabled, time()]);
          audit($db, $u, 'ai.profile_add', 'ai_profile', (int)$db->lastInsertId());
        }
        flash_set('ok', t('saved'));
      } catch (PDOException) {
        flash_set('err', t('already_exists'));
      }
      return true;

    case 'delete_profile':
      $id = (int)($_POST['profile_id'] ?? 0);
      if ($id > 0) {
        $st = $db->prepare('SELECT user_id FROM ai_profiles WHERE id = ?');
        $st->execute([$id]);
        $botId = $st->fetchColumn();
        $db->prepare('DELETE FROM ai_profiles WHERE id = ?')->execute([$id]);
        if ($botId) $db->prepare('UPDATE users SET banned = 1 WHERE id = ?')->execute([$botId]);
        audit($db, $u, 'ai.profile_delete', 'ai_profile', $id);
        flash_set('ok', t('saved'));
      }
      return true;

    case 'save_turnstile':
      settings_set($db, 'turnstile_enabled', isset($_POST['ts_enabled']) ? '1' : '0');
      settings_set($db, 'turnstile_site_key', mb_substr(trim((string)($_POST['ts_site'] ?? '')), 0, 100));
      $sec = trim((string)($_POST['ts_secret'] ?? ''));
      if ($sec !== '') settings_set($db, 'turnstile_secret_enc', secret_encrypt($sec, $config['app_key']));
      audit($db, $u, 'turnstile.settings');
      flash_set('ok', t('settings_saved'));
      return true;

    case 'set_verified':
      $id = admin_user_id($db, (string)($_POST['username'] ?? ''));
      if ($id > 0) {
        $v = isset($_POST['verified']) ? 1 : 0;
        $db->prepare('UPDATE users SET is_verified = ? WHERE id = ?')->execute([$v, $id]);
        audit($db, $u, 'user.verified', 'user', $id, ['verified' => $v]);
        flash_set('ok', t('saved'));
      } else {
        flash_set('err', t('not_found'));
      }
      return true;

    case 'assign_role':
      $id  = admin_user_id($db, (string)($_POST['username'] ?? ''));
      $rid = (int)($_POST['role_id'] ?? 0);
      if ($id > 0) {
        $db->prepare('UPDATE users SET role_id = ? WHERE id = ?')->execute([$rid > 0 ? $rid : null, $id]);
        audit($db, $u, 'user.role_assign', 'user', $id, ['role_id' => $rid]);
        flash_set('ok', t('saved'));
      } else {
        flash_set('err', t('not_found'));
      }
      return true;

    case 'create_role':
      $name  = mb_substr(trim((string)($_POST['role_name'] ?? '')), 0, 32);
      $color = (string)($_POST['role_color'] ?? '#6366f1');
      if (!preg_match('/^#[0-9A-Fa-f]{6}$/', $color)) $color = '#6366f1';
      $power = max(0, min(99, (int)($_POST['role_power'] ?? 0)));
      if ($name !== '') {
        try {
          $db->prepare('INSERT INTO roles(name, color_hex, power_level) VALUES(?, ?, ?)')->execute([$name, $color, $power]);
          audit($db, $u, 'role.create', 'role', (int)$db->lastInsertId());
          flash_set('ok', t('saved'));
        } catch (PDOException) {
          flash_set('err', t('already_exists'));
        }
      }
      return true;

    case 'delete_role':
      $rid = (int)($_POST['role_id'] ?? 0);
      if ($rid > 0) {
        $db->prepare('DELETE FROM roles WHERE id = ?')->execute([$rid]);
        audit($db, $u, 'role.delete', 'role', $rid);
        flash_set('ok', t('saved'));
      }
      return true;

    case 'set_category_tags':
      $cid = (int)($_POST['category_id'] ?? 0);
      if ($cid > 0) {
        $db->prepare('DELETE FROM category_tags WHERE category_id = ?')->execute([$cid]);
        $names = array_slice(array_filter(array_map('trim', explode(',', (string)($_POST['tags'] ?? '')))), 0, 10);
        foreach ($names as $n) {
          $tid = tag_get_or_create($db, mb_substr($n, 0, 30));
          if ($tid > 0) {
            $db->prepare('INSERT OR IGNORE INTO category_tags(category_id, tag_id) VALUES(?, ?)')->execute([$cid, $tid]);
          }
        }
        audit($db, $u, 'category.tags', 'category', $cid);
        flash_set('ok', t('saved'));
      }
      return true;
  }
  return false;
}
PHP

  cat > "$APP_DIR/app/ai-worker.php" <<'PHP'
<?php
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
$cfg = require dirname(__DIR__) . '/config/config.php';
ini_set('session.save_path', dirname($cfg['db_path']) . '/sessions');
require __DIR__ . '/bootstrap.php';
$n = ai_run_jobs($db, $config, 5);
if ($n > 0) echo date('c') . " processed $n\n";
PHP

  chown -R root:root "$APP_DIR/app"
  find "$APP_DIR/app" -type d -exec chmod 0755 {} \;
  find "$APP_DIR/app" -type f -exec chmod 0644 {} \;
  ok "app/"
}

write_views() {
  cat > "$APP_DIR/views/layout.php" <<'PHP'
<?php /* @var string $content @var string $title */
$u = auth_user();
$appName = $GLOBALS['__app_name'] ?? 'LiteForum';
$appTagline = $GLOBALS['__app_tagline'] ?? '';
$flash = flash_get();
$unread = $u ? notif_unread_count($GLOBALS['db'], (int)$u['id']) : 0;
$online = online_count($GLOBALS['db']);
$lcNow = $_SESSION['ui_lang'] ?? 'en';
?>
<!doctype html>
<html lang="<?= e($lcNow) ?>" dir="<?= $lcNow === 'ar' ? 'rtl' : 'ltr' ?>">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= e($title ?? $appName) ?> · <?= e($appName) ?></title>
<style>
  :root { <?= theme_css_vars() ?> }
  *{box-sizing:border-box}
  html{scroll-behavior:smooth}
  body{background:var(--bg);color:var(--fg);font-family:ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;margin:0;min-height:100vh;line-height:1.55;overflow-x:hidden}
  body::before{content:"";position:fixed;top:-200px;left:50%;transform:translateX(-50%);width:1000px;height:600px;background:radial-gradient(circle,var(--glow),transparent 70%);pointer-events:none;z-index:0;animation:float 12s ease-in-out infinite}
  body::after{content:"";position:fixed;inset:0;background-image:radial-gradient(var(--border) 1px,transparent 1px);background-size:32px 32px;opacity:.4;pointer-events:none;z-index:0}
  @keyframes float{0%,100%{transform:translateX(-50%) translateY(0)}50%{transform:translateX(-50%) translateY(-30px)}}
  @keyframes fadeIn{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:translateY(0)}}
  @keyframes slideDown{from{opacity:0;transform:translateY(-20px)}to{opacity:1;transform:translateY(0)}}
  a{color:var(--accent-400);text-decoration:none;transition:color .15s}
  a:hover{color:var(--accent-500);text-decoration:underline}
  .container{max-width:1160px;margin:0 auto;padding:2rem 1.25rem;position:relative;z-index:1}
  .glass{background:var(--panel);backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);border:1px solid var(--border);border-radius:1rem;box-shadow:0 25px 50px -12px rgba(0,0,0,.4);transition:border-color .2s,box-shadow .2s}
  .glass:hover{border-color:color-mix(in srgb,var(--accent-500) 30%,var(--border))}
  .card{padding:1.75rem}
  header.nav{position:sticky;top:0;z-index:50;border-bottom:1px solid var(--border);background:color-mix(in srgb,var(--bg) 80%,transparent);backdrop-filter:blur(16px);-webkit-backdrop-filter:blur(16px)}
  header.nav .inner{max-width:1160px;margin:0 auto;padding:.9rem 1.25rem;display:flex;justify-content:space-between;align-items:center;gap:.75rem;flex-wrap:wrap}
  .logo{display:flex;gap:.6rem;align-items:center;color:var(--fg);font-weight:700;font-size:1.1rem;letter-spacing:-.02em}
  .logo .mark{width:34px;height:34px;border-radius:.6rem;background:linear-gradient(135deg,var(--accent-500),var(--accent-600));display:flex;align-items:center;justify-content:center;font-weight:800;color:#fff;box-shadow:0 4px 12px var(--glow)}
  nav.actions{display:flex;gap:.5rem;align-items:center;flex-wrap:wrap}
  nav.actions a{padding:.45rem .75rem;border-radius:.55rem;font-size:.9rem}
  nav.actions a:hover{background:var(--panel2);color:var(--fg);text-decoration:none}
  nav.actions .icon-link{position:relative;padding:.45rem .55rem}
  .badge-notif{position:absolute;top:-2px;right:-2px;background:#ef4444;color:#fff;border-radius:999px;font-size:10px;font-weight:700;min-width:16px;height:16px;display:flex;align-items:center;justify-content:center;padding:0 4px;box-shadow:0 0 0 2px var(--bg)}
  input,textarea,select{background:var(--bg2);color:var(--fg);border:1px solid var(--border);border-radius:.55rem;padding:.65rem .85rem;width:100%;font:inherit;font-size:.95rem;transition:border-color .15s,box-shadow .15s}
  input:focus,textarea:focus,select:focus{outline:none;border-color:var(--accent-500);box-shadow:0 0 0 3px var(--glow)}
  input[type=checkbox]{width:auto}
  textarea{resize:vertical;min-height:100px;font-family:inherit}
  button,.btn{background:linear-gradient(135deg,var(--accent-500),var(--accent-600));color:#fff;border:0;border-radius:.55rem;padding:.65rem 1.1rem;cursor:pointer;font-weight:600;font-size:.95rem;transition:transform .1s,filter .15s,box-shadow .2s;display:inline-flex;align-items:center;gap:.4rem;width:auto}
  button:hover,.btn:hover{filter:brightness(1.1);box-shadow:0 8px 20px -4px var(--glow);text-decoration:none;color:#fff}
  button:active,.btn:active{transform:translateY(1px)}
  button:disabled{opacity:.5;cursor:not-allowed;filter:none}
  .btn-ghost{background:transparent;border:1px solid var(--border);color:var(--fg)}
  .btn-ghost:hover{background:var(--panel2);filter:none;box-shadow:none;color:var(--fg)}
  .btn-sm{padding:.4rem .8rem;font-size:.85rem}
  .btn-danger{background:linear-gradient(135deg,#ef4444,#dc2626)}
  .muted{color:var(--fg-muted)}
  .text-sm{font-size:.875rem}
  .flex{display:flex;gap:.75rem;align-items:center}
  .flex-wrap{flex-wrap:wrap}
  .grid{display:grid;gap:1rem}
  .field{display:grid;gap:.35rem;font-size:.9rem}
  .field > span{color:var(--fg-muted)}
  .sec-title{margin:0 0 1rem;font-size:1.15rem}
  .hint{color:var(--fg-muted);font-size:.85rem;margin:.75rem 0 0}
  table{width:100%;border-collapse:collapse}
  th,td{text-align:left;padding:.75rem .9rem;border-bottom:1px solid var(--border);vertical-align:middle}
  th{font-size:.78rem;text-transform:uppercase;letter-spacing:.05em;color:var(--fg-muted);font-weight:600}
  tr:hover{background:var(--panel2)}
  code{background:var(--bg2);padding:1px 6px;border-radius:4px;color:var(--accent-400);font-size:.9em;font-family:ui-monospace,monospace}
  .flash{padding:.85rem 1.1rem;border-radius:.75rem;margin-bottom:1rem;display:flex;align-items:center;gap:.6rem;animation:slideDown .3s ease;font-size:.9rem}
  .flash-ok{background:rgba(16,185,129,.12);border:1px solid rgba(16,185,129,.35);color:#34d399}
  .flash-err{background:rgba(239,68,68,.12);border:1px solid rgba(239,68,68,.35);color:#fca5a5}
  .flash-info{background:rgba(99,102,241,.12);border:1px solid rgba(99,102,241,.35);color:#a5b4fc}
  .hero{padding:3rem 1rem;text-align:center;animation:fadeIn .4s ease}
  .hero h1{font-size:2.5rem;margin:0 0 .75rem;font-weight:800;letter-spacing:-.03em;background:linear-gradient(135deg,var(--fg),var(--accent-400));-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent}
  .hero p{color:var(--fg-muted);font-size:1.05rem;margin:0 auto;max-width:600px}
  .stat-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:1rem;margin-bottom:1.5rem}
  .stat-card{text-align:center;padding:1.25rem;background:var(--panel);border:1px solid var(--border);border-radius:.85rem;transition:transform .2s,border-color .2s}
  .stat-card:hover{transform:translateY(-2px);border-color:var(--accent-500)}
  .stat-card .num{font-size:1.75rem;font-weight:800;color:var(--accent-400);line-height:1}
  .stat-card .label{font-size:.75rem;text-transform:uppercase;letter-spacing:.05em;color:var(--fg-muted);margin-top:.35rem;font-weight:600}
  .category-card{display:flex;gap:1rem;align-items:center;padding:1.1rem 1.25rem;background:var(--panel);border:1px solid var(--border);border-radius:.85rem;transition:transform .2s,border-color .2s,background .2s;animation:fadeIn .3s ease;color:inherit}
  .category-card:hover{transform:translateX(4px);border-color:var(--accent-500);background:var(--panel2);text-decoration:none}
  .category-card .icon{font-size:2rem;width:52px;height:52px;display:flex;align-items:center;justify-content:center;background:var(--panel2);border-radius:.75rem;border:1px solid var(--border);flex-shrink:0}
  .category-card .info{flex:1;min-width:0}
  .category-card .info h3{margin:0 0 .25rem;font-size:1.05rem;color:var(--fg)}
  .category-card .info p{margin:0;color:var(--fg-muted);font-size:.85rem}
  .category-card .count{text-align:center;color:var(--fg-muted);font-size:.75rem;text-transform:uppercase;letter-spacing:.05em;min-width:60px}
  .category-card .count strong{display:block;color:var(--accent-400);font-size:1.4rem;font-weight:800}
  .topic-row{display:flex;gap:.85rem;align-items:flex-start;padding:1rem 1.15rem;border-bottom:1px solid var(--border);transition:background .15s;color:inherit}
  .topic-row:hover{background:var(--panel2);text-decoration:none}
  .topic-row .info{flex:1;min-width:0}
  .topic-row .title{font-weight:600;color:var(--fg);font-size:1rem;display:inline-flex;align-items:center;gap:.4rem;flex-wrap:wrap}
  .topic-row .meta{color:var(--fg-muted);font-size:.82rem;margin-top:.25rem;display:flex;gap:.75rem;flex-wrap:wrap}
  .topic-row .counts{display:flex;gap:1rem;text-align:center;flex-shrink:0}
  .topic-row .counts .c{font-size:.85rem;color:var(--fg-muted)}
  .topic-row .counts .c strong{display:block;color:var(--fg);font-weight:700}
  .pill{display:inline-block;padding:.15rem .55rem;border-radius:999px;background:var(--panel2);border:1px solid var(--border);font-size:.72rem;color:var(--fg-muted);font-weight:600;text-transform:uppercase;letter-spacing:.04em}
  .pill-accent{background:var(--glow);border-color:var(--accent-500);color:var(--accent-400)}
  .pill-danger{background:rgba(239,68,68,.15);border-color:#ef4444;color:#fca5a5}
  .post-card{padding:1.25rem 1.5rem;background:var(--panel);border:1px solid var(--border);border-radius:.85rem;margin-bottom:.85rem;animation:fadeIn .3s ease}
  .post-card .head{display:flex;gap:.75rem;align-items:center;margin-bottom:.85rem;font-size:.85rem;flex-wrap:wrap}
  .post-card .head .author{font-weight:600;color:var(--fg)}
  .post-card .head .time{color:var(--fg-muted)}
  .post-card .body{color:var(--fg);line-height:1.65;word-wrap:break-word;overflow-wrap:break-word}
  .post-card .reactions{display:flex;gap:.4rem;margin-top:.75rem;flex-wrap:wrap}
  .react-btn{background:transparent;border:1px solid var(--border);border-radius:.55rem;padding:.3rem .6rem;cursor:pointer;color:var(--fg);font-size:.85rem;display:inline-flex;align-items:center;gap:.25rem;box-shadow:none}
  .react-btn:hover{background:var(--panel2);border-color:var(--accent-500);transform:scale(1.05);box-shadow:none}
  .react-btn.active{background:var(--glow);border-color:var(--accent-500);color:var(--accent-400)}
  .breadcrumb{display:flex;gap:.5rem;align-items:center;font-size:.85rem;color:var(--fg-muted);margin-bottom:1rem;flex-wrap:wrap}
  .avatar-lg{width:96px;height:96px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:2.5rem;font-weight:800;color:#fff;box-shadow:0 12px 24px var(--glow)}
  .mod-bar{display:flex;gap:.4rem;flex-wrap:wrap;margin-top:.85rem;padding-top:.85rem;border-top:1px dashed var(--border)}
  .mod-bar form{margin:0;display:inline}
  .tabs{display:flex;gap:.4rem;flex-wrap:wrap;margin:0 0 1.25rem;padding-bottom:.75rem;border-bottom:1px solid var(--border)}
  .tabs a{padding:.5rem .9rem;border-radius:.55rem;color:var(--fg-muted);font-size:.9rem;font-weight:600}
  .tabs a:hover{background:var(--panel2);color:var(--fg);text-decoration:none}
  .tabs a.on{background:var(--glow);color:var(--accent-400)}
  .footer{padding:3rem 1.25rem 2rem;text-align:center;color:var(--fg-muted);font-size:.85rem;border-top:1px solid var(--border);margin-top:3rem}
  .online-dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:#10b981;box-shadow:0 0 8px #10b981;margin-right:.4rem}
  @media (max-width:640px){
    .hero h1{font-size:1.8rem}
    .container{padding:1.25rem 1rem}
    .topic-row .counts{display:none}
    .card{padding:1.25rem}
    nav.actions{gap:.25rem}
    nav.actions a,nav.actions button{font-size:.82rem;padding:.35rem .6rem}
    .stat-grid{grid-template-columns:repeat(2,1fr)}
  }
</style>
</head>
<body>
<header class="nav"><div class="inner">
  <a class="logo" href="/"><span class="mark"><?= e(mb_substr($appName, 0, 1)) ?></span><span><?= e($appName) ?></span></a>
  <nav class="actions">
    <a href="/activity.php" title="<?= e(t('activity')) ?>">📊</a>
    <a href="/stats.php" title="<?= e(t('stats')) ?>">📈</a>
    <form action="/search.php" method="get" style="margin:0">
      <input name="q" placeholder="<?= e(t('search_placeholder')) ?>" style="width:150px;padding:.4rem .65rem;font-size:.85rem">
    </form>
    <form method="post" action="/lang.php" style="margin:0">
      <?= csrf_field() ?>
      <select name="lang" data-autosubmit style="width:auto;padding:.35rem .55rem;font-size:.8rem">
        <?php foreach ($GLOBALS['__config_available_langs'] as $lc): ?>
          <option value="<?= e($lc) ?>" <?= $lcNow === $lc ? 'selected' : '' ?>><?= e(strtoupper($lc)) ?></option>
        <?php endforeach; ?>
      </select>
    </form>
    <?php if ($u): ?>
      <a href="/notifications.php" class="icon-link" title="<?= e(t('notifications')) ?>">🔔<?php if ($unread > 0): ?><span class="badge-notif"><?= $unread ?></span><?php endif; ?></a>
      <a href="/user.php?u=<?= e($u['username']) ?>" class="flex" style="gap:.4rem">
        <?= user_avatar($u['username'], $u['avatar_color'] ?? '#6366f1', 28) ?>
        <span style="font-size:.88rem;font-weight:600">@<?= e($u['username']) ?></span>
      </a>
      <?php if (is_admin($u)): ?><a href="/admin.php" class="icon-link" title="<?= e(t('admin_panel')) ?>">⚙</a><?php endif; ?>
      <a href="/settings.php" class="icon-link" title="<?= e(t('settings')) ?>">🛠</a>
      <form method="post" action="/logout.php" style="margin:0"><?= csrf_field() ?><button class="btn-ghost btn-sm" type="submit"><?= e(t('logout')) ?></button></form>
    <?php else: ?>
      <a href="/login.php"><?= e(t('login')) ?></a>
      <a href="/register.php" class="btn btn-sm" style="color:#fff"><?= e(t('register')) ?></a>
    <?php endif; ?>
  </nav>
</div></header>
<main class="container">
<?php if ($flash): ?>
  <div class="flash flash-<?= e($flash['type']) ?>">
    <span><?= $flash['type'] === 'ok' ? '✅' : ($flash['type'] === 'err' ? '❌' : 'ℹ️') ?></span>
    <span><?= e($flash['msg']) ?></span>
  </div>
<?php endif; ?>
<?= $content ?>
</main>
<footer class="footer">
  <p><strong><?= e($appName) ?></strong> <?= e($appTagline) ?></p>
  <p style="margin-top:.5rem"><span class="online-dot"></span><?= (int)$online ?> <?= e(t('online_users')) ?></p>
</footer>
<script src="/assets/app.js" defer></script>
</body></html>
PHP

  cat > "$APP_DIR/views/home.php" <<'PHP'
<?php /* @var array $cats @var array $recent @var array $stats */ $lc = $_SESSION['ui_lang'] ?? 'en'; ?>
<div class="hero">
  <h1><?= e($GLOBALS['__app_name']) ?></h1>
  <p><?= e($GLOBALS['__app_tagline']) ?></p>
</div>

<div class="stat-grid">
  <div class="stat-card"><div class="num"><?= (int)$stats['topics'] ?></div><div class="label"><?= e(t('total_topics')) ?></div></div>
  <div class="stat-card"><div class="num"><?= (int)$stats['posts'] ?></div><div class="label"><?= e(t('total_posts')) ?></div></div>
  <div class="stat-card"><div class="num"><?= (int)$stats['users'] ?></div><div class="label"><?= e(t('total_users')) ?></div></div>
  <div class="stat-card"><div class="num"><?= (int)$stats['online'] ?></div><div class="label"><?= e(t('online_users')) ?></div></div>
</div>

<h2 class="sec-title" style="margin:1.5rem 0 1rem;font-size:1.25rem"><?= e(t('categories')) ?></h2>
<div class="grid" style="margin-bottom:2rem">
  <?php foreach ($cats as $c): ?>
    <a href="/category.php?slug=<?= e($c['slug']) ?>" class="category-card">
      <span class="icon"><?= e($c['icon'] ?? '💬') ?></span>
      <div class="info">
        <h3><?= e(cat_name($c, $lc)) ?></h3>
        <?php $desc = cat_desc($c, $lc); if ($desc): ?><p><?= e($desc) ?></p><?php endif; ?>
      </div>
      <div class="count"><strong><?= (int)$c['n'] ?></strong><?= e(t('topics')) ?></div>
    </a>
  <?php endforeach; ?>
</div>

<h2 class="sec-title" style="margin:1.5rem 0 1rem;font-size:1.25rem"><?= e(t('recent_topics')) ?></h2>
<div class="glass">
  <?php if (empty($recent)): ?>
    <div class="card muted" style="text-align:center"><?= e(t('no_topics_yet')) ?></div>
  <?php else: foreach ($recent as $r): ?>
    <a href="/topic.php?id=<?= (int)$r['id'] ?>" class="topic-row">
      <?= user_avatar($r['username'], '#6366f1', 36) ?>
      <div class="info">
        <div class="title"><?php if ((int)$r['is_pinned']): ?><span class="pill pill-accent">📌</span><?php endif; ?> <?= e($r['title']) ?></div>
        <div class="meta">
          <span>@<?= e($r['username']) ?></span>
          <span>· <?= e($r['cat_slug']) ?></span>
          <span>· <?= time_ago((int)$r['updated_at']) ?></span>
        </div>
      </div>
      <div class="counts"><div class="c"><strong><?= (int)$r['post_count'] ?></strong><?= e(t('posts')) ?></div></div>
    </a>
  <?php endforeach; endif; ?>
</div>
PHP

  cat > "$APP_DIR/views/category.php" <<'PHP'
<?php /* @var array $cat @var array $topics @var int $page @var int $total @var string $tagSlug @var string $tagq @var array $tagsByTopic @var array $allCatTags @var array $tagHits */ $lc = $_SESSION['ui_lang'] ?? 'en'; ?>
<div class="breadcrumb">
  <a href="/"><?= e(t('home')) ?></a> <span>›</span> <span><?= e(cat_name($cat, $lc)) ?></span>
</div>
<div class="flex" style="justify-content:space-between;margin-bottom:1.25rem;flex-wrap:wrap">
  <h1 style="margin:0;font-size:1.75rem;letter-spacing:-.02em"><?= e($cat['icon']) ?> <?= e(cat_name($cat, $lc)) ?></h1>
  <?php if (auth_user()): ?>
    <a href="/new-topic.php?cat=<?= (int)$cat['id'] ?>" class="btn">+ <?= e(t('new_topic')) ?></a>
  <?php endif; ?>
</div>
<?php $desc = cat_desc($cat, $lc); if ($desc): ?>
  <p class="muted" style="margin:-.5rem 0 1.25rem"><?= e($desc) ?></p>
<?php endif; ?>

<?php if (!empty($allCatTags)): ?>
<div class="flex flex-wrap" style="gap:.4rem;margin:0 0 1rem">
  <a href="/category.php?slug=<?= e($cat['slug']) ?>" class="pill<?= $tagSlug === '' ? ' pill-accent' : '' ?>"><?= e(t('all')) ?></a>
  <?php foreach ($allCatTags as $tg): ?>
    <a href="/category.php?slug=<?= e($cat['slug']) ?>&amp;tag=<?= e(rawurlencode($tg['slug'])) ?>" class="pill<?= $tagSlug === $tg['slug'] ? ' pill-accent' : '' ?>">#<?= e($tg['name']) ?></a>
  <?php endforeach; ?>
</div>
<?php endif; ?>
<form method="get" action="/category.php" class="flex flex-wrap" style="gap:.5rem;margin-bottom:1rem">
  <input type="hidden" name="slug" value="<?= e($cat['slug']) ?>">
  <input name="tq" value="<?= e($tagq) ?>" placeholder="<?= e(t('tag_search')) ?>" maxlength="40" style="max-width:240px">
  <button class="btn-ghost btn btn-sm" type="submit"><?= e(t('search')) ?></button>
</form>
<?php if ($tagq !== ''): ?>
  <div class="flex flex-wrap" style="gap:.4rem;margin-bottom:1rem">
    <?php if (empty($tagHits)): ?><span class="muted text-sm"><?= e(t('no_results')) ?></span><?php endif; ?>
    <?php foreach ($tagHits as $h): ?>
      <a href="/category.php?slug=<?= e($cat['slug']) ?>&amp;tag=<?= e(rawurlencode($h['slug'])) ?>" class="pill">#<?= e($h['name']) ?></a>
    <?php endforeach; ?>
  </div>
<?php endif; ?>

<div class="glass">
  <?php if (empty($topics)): ?>
    <div class="card muted" style="text-align:center"><?= e(t('no_topics_yet')) ?></div>
  <?php else: foreach ($topics as $tp): ?>
    <a href="/topic.php?id=<?= (int)$tp['id'] ?>" class="topic-row">
      <?= user_avatar($tp['username'], $tp['avatar_color'] ?? '#6366f1', 36) ?>
      <div class="info">
        <div class="title">
          <?php if ((int)$tp['is_pinned']): ?><span class="pill pill-accent">📌</span><?php endif; ?>
          <?php if ((int)$tp['is_locked']): ?><span class="pill">🔒</span><?php endif; ?>
          <?= e($tp['title']) ?>
          <?php foreach (($tagsByTopic[(int)$tp['id']] ?? []) as $tg): ?>
            <span class="pill" style="font-size:.7rem">#<?= e($tg['name']) ?></span>
          <?php endforeach; ?>
        </div>
        <div class="meta">
          <span>@<?= e($tp['username']) ?></span><?= verified_badge((int)($tp['is_verified'] ?? 0)) ?>
          <span>· <?= time_ago((int)$tp['updated_at']) ?></span>
          <span>· <?= (int)$tp['views'] ?> <?= e(t('views')) ?></span>
        </div>
      </div>
      <div class="counts"><div class="c"><strong><?= (int)$tp['post_count'] ?></strong><?= e(t('posts')) ?></div></div>
    </a>
  <?php endforeach; endif; ?>
</div>
<?php if (($total ?? 0) > 25):
  $totalPages = (int)ceil($total / 25);
  $tagParam = $tagSlug !== '' ? '&amp;tag=' . e(rawurlencode($tagSlug)) : '';
?>
  <div class="flex" style="justify-content:center;margin-top:1.5rem;gap:.5rem">
    <?php for ($i = 1; $i <= $totalPages; $i++): ?>
      <a href="?slug=<?= e($cat['slug']) ?>&amp;page=<?= $i ?><?= $tagParam ?>" class="<?= $i === $page ? 'btn' : 'btn-ghost btn' ?>" style="padding:.4rem .8rem;font-size:.85rem"><?= $i ?></a>
    <?php endfor; ?>
  </div>
<?php endif; ?>
PHP

  cat > "$APP_DIR/views/topic.php" <<'PHP'
<?php /* @var array $topic @var array $posts @var bool $watching @var array $reactions @var array $myReacted @var array $topicTags */ $u = auth_user(); ?>
<div class="breadcrumb">
  <a href="/"><?= e(t('home')) ?></a> <span>›</span>
  <a href="/category.php?slug=<?= e($topic['cat_slug']) ?>"><?= e($topic['cat_name']) ?></a> <span>›</span>
  <span><?= e(mb_substr($topic['title'], 0, 50)) ?><?= mb_strlen($topic['title']) > 50 ? '…' : '' ?></span>
</div>
<div class="glass card" style="margin-bottom:1.25rem">
  <h1 style="margin:0 0 .5rem;font-size:1.5rem;letter-spacing:-.02em">
    <?php if ((int)$topic['is_pinned']): ?><span class="pill pill-accent">📌</span><?php endif; ?>
    <?php if ((int)$topic['is_locked']): ?><span class="pill">🔒</span><?php endif; ?>
    <?= e($topic['title']) ?>
  </h1>
  <?php if (!empty($topicTags)): ?>
    <div class="flex flex-wrap" style="gap:.35rem;margin:-.25rem 0 .6rem">
      <?php foreach ($topicTags as $tg): ?>
        <a class="pill" href="/category.php?slug=<?= e($topic['cat_slug']) ?>&amp;tag=<?= e(rawurlencode($tg['slug'])) ?>">#<?= e($tg['name']) ?></a>
      <?php endforeach; ?>
    </div>
  <?php endif; ?>
  <div class="flex flex-wrap muted" style="font-size:.85rem">
    <?= user_avatar($topic['username'], '#6366f1', 24) ?>
    <span>@<?= e($topic['username']) ?></span><?= verified_badge((int)($topic['is_verified'] ?? 0)) ?>
    <span>· <?= date('Y-m-d H:i', (int)$topic['created_at']) ?></span>
    <span>· <?= (int)$topic['views'] ?> <?= e(t('views')) ?></span>
  </div>
  <?php if ($u): ?>
  <div class="flex flex-wrap" style="margin-top:.85rem">
    <form method="post" action="/topic.php?id=<?= (int)$topic['id'] ?>" style="margin:0">
      <?= csrf_field() ?><input type="hidden" name="action" value="toggle_watch">
      <button class="btn-ghost btn btn-sm" type="submit"><?= $watching ? '👁 ' : '🔔 ' ?><?= e($watching ? t('unwatch_topic') : t('watch_topic')) ?></button>
    </form>
    <?php if (is_mod($u)): ?>
      <form method="post" action="/mod.php" style="margin:0">
        <?= csrf_field() ?>
        <input type="hidden" name="action" value="pin">
        <input type="hidden" name="topic_id" value="<?= (int)$topic['id'] ?>">
        <input type="hidden" name="state" value="<?= (int)$topic['is_pinned'] ? 0 : 1 ?>">
        <button class="btn-ghost btn btn-sm" type="submit">📌 <?= e((int)$topic['is_pinned'] ? t('unpin') : t('pin')) ?></button>
      </form>
      <form method="post" action="/mod.php" style="margin:0">
        <?= csrf_field() ?>
        <input type="hidden" name="action" value="lock">
        <input type="hidden" name="topic_id" value="<?= (int)$topic['id'] ?>">
        <input type="hidden" name="state" value="<?= (int)$topic['is_locked'] ? 0 : 1 ?>">
        <button class="btn-ghost btn btn-sm" type="submit">🔒 <?= e((int)$topic['is_locked'] ? t('unlock') : t('lock')) ?></button>
      </form>
      <?php if (is_admin($u)): ?>
        <form method="post" action="/mod.php" style="margin:0" data-confirm="<?= e(t('delete_confirm')) ?>">
          <?= csrf_field() ?>
          <input type="hidden" name="action" value="delete_topic">
          <input type="hidden" name="topic_id" value="<?= (int)$topic['id'] ?>">
          <button class="btn-danger btn btn-sm" type="submit">🗑 <?= e(t('delete_topic')) ?></button>
        </form>
      <?php endif; ?>
    <?php endif; ?>
  </div>
  <?php endif; ?>
</div>

<?php foreach ($posts as $p):
  $pid = (int)$p['id'];
  $postReacts = $reactions[$pid] ?? [];
  $myReacts   = $myReacted[$pid] ?? [];
?>
  <div class="post-card" style="<?= (int)$p['is_deleted'] ? 'opacity:.5' : '' ?>">
    <div class="head">
      <?= user_avatar($p['username'], $p['avatar_color'] ?? '#6366f1', 28) ?>
      <span class="author">@<?= e($p['username']) ?></span><?= verified_badge((int)($p['is_verified'] ?? 0)) ?>
      <?php if (!empty($p['role_name'])): ?><span class="pill" style="background:<?= e($p['role_color']) ?>;color:#fff;font-size:.7rem"><?= e($p['role_name']) ?></span><?php endif; ?>
      <span class="time">· <?= time_ago((int)$p['created_at']) ?></span>
      <?php if (!empty($p['edited_at'])): ?><span class="time">· <?= e(t('edited')) ?></span><?php endif; ?>
    </div>
    <div class="body"><?= (int)$p['is_deleted'] ? '<em class="muted">' . e(t('deleted_post')) . '</em>' : render_post($p['body']) ?></div>

    <?php if (!$u || (int)$p['is_deleted']): ?>
      <?php if (!empty($postReacts)): ?>
        <div class="reactions">
          <?php foreach ($postReacts as $emoji => $cnt): if ($cnt > 0): ?>
            <span class="react-btn"><?= e($emoji) ?> <?= (int)$cnt ?></span>
          <?php endif; endforeach; ?>
        </div>
      <?php endif; ?>
    <?php else: ?>
      <div class="reactions">
        <?php foreach (['👍', '❤️', '🔥', '😂', '😮'] as $emoji):
          $cnt = $postReacts[$emoji] ?? 0;
          $active = in_array($emoji, $myReacts, true);
        ?>
          <form method="post" action="/react.php" style="margin:0;display:inline">
            <?= csrf_field() ?>
            <input type="hidden" name="post_id" value="<?= $pid ?>">
            <input type="hidden" name="emoji" value="<?= e($emoji) ?>">
            <input type="hidden" name="back" value="/topic.php?id=<?= (int)$topic['id'] ?>">
            <button class="react-btn <?= $active ? 'active' : '' ?>" type="submit"><?= e($emoji) ?><?php if ($cnt > 0): ?> <?= (int)$cnt ?><?php endif; ?></button>
          </form>
        <?php endforeach; ?>
      </div>
    <?php endif; ?>

    <?php if ($u && is_mod($u) && !(int)$p['is_deleted']): ?>
      <div class="mod-bar">
        <form method="post" action="/mod.php" style="margin:0" data-confirm="<?= e(t('delete_confirm')) ?>">
          <?= csrf_field() ?>
          <input type="hidden" name="action" value="delete_post">
          <input type="hidden" name="post_id" value="<?= $pid ?>">
          <input type="hidden" name="topic_id" value="<?= (int)$topic['id'] ?>">
          <button class="btn-ghost btn btn-sm" type="submit">🗑 <?= e(t('delete_post')) ?></button>
        </form>
      </div>
    <?php endif; ?>
  </div>
<?php endforeach; ?>

<?php if ($u && empty($topic['is_locked'])): ?>
<div class="glass card" style="margin-top:1.5rem">
  <h2 class="sec-title"><?= e(t('reply_to_topic')) ?></h2>
  <form method="post" action="/topic.php?id=<?= (int)$topic['id'] ?>" class="grid" enctype="multipart/form-data">
    <?= csrf_field() ?><input type="hidden" name="action" value="reply">
    <label class="field"><span><?= e(t('image_upload')) ?></span><input type="file" name="image" accept="image/jpeg,image/png,image/gif,image/webp"></label>
    <textarea name="body" rows="6" required placeholder="**bold** *italic* `code` [link](url) @user &gt; quote"></textarea>
    <div><button type="submit"><?= e(t('post_reply')) ?></button></div>
  </form>
</div>
<?php elseif (!$u): ?>
<div class="glass card" style="margin-top:1.5rem;text-align:center">
  <a href="/login.php"><?= e(t('login')) ?></a> — <?= e(t('reply')) ?>
</div>
<?php endif; ?>
PHP

  cat > "$APP_DIR/views/new-topic.php" <<'PHP'
<?php /* @var array $cat @var string $error @var array $allowedTags */ $lc = $_SESSION['ui_lang'] ?? 'en'; ?>
<div class="breadcrumb">
  <a href="/"><?= e(t('home')) ?></a> <span>›</span>
  <a href="/category.php?slug=<?= e($cat['slug']) ?>"><?= e(cat_name($cat, $lc)) ?></a> <span>›</span>
  <span><?= e(t('new_topic')) ?></span>
</div>
<div class="glass card" style="max-width:720px;margin:0 auto">
  <h1 style="margin:0 0 1.25rem;font-size:1.5rem"><?= e(t('new_topic')) ?></h1>
  <?php if (!empty($error)): ?><div class="flash flash-err"><?= e($error) ?></div><?php endif; ?>
  <form method="post" class="grid" enctype="multipart/form-data">
    <?= csrf_field() ?>
    <input name="title" required minlength="3" maxlength="200" placeholder="<?= e(t('title')) ?>">
    <textarea name="body" rows="10" required placeholder="<?= e(t('body')) ?>"></textarea>
    <?php if (!empty($allowedTags)): ?>
    <fieldset style="border:1px solid var(--border);border-radius:.5rem;padding:.6rem .8rem">
      <legend class="muted text-sm"><?= e(t('tags_max')) ?></legend>
      <?php foreach ($allowedTags as $tg): ?>
        <label class="pill" style="cursor:pointer;margin:.2rem"><input type="checkbox" name="tags[]" value="<?= (int)$tg['id'] ?>" style="width:auto"> #<?= e($tg['name']) ?></label>
      <?php endforeach; ?>
    </fieldset>
    <?php endif; ?>
    <label class="field"><span><?= e(t('image_upload')) ?></span><input type="file" name="image" accept="image/jpeg,image/png,image/gif,image/webp"></label>
    <div><button type="submit"><?= e(t('submit')) ?></button></div>
  </form>
</div>
PHP

  cat > "$APP_DIR/views/login.php" <<'PHP'
<?php /* @var string $error */ $config = $GLOBALS['__config']; ?>
<div class="glass card" style="max-width:440px;margin:2rem auto;animation:fadeIn .3s ease">
  <h1 style="margin:0 0 1.25rem;font-size:1.5rem"><?= e(t('login')) ?></h1>
  <?php if (!empty($error)): ?><div class="flash flash-err"><?= e($error) ?></div><?php endif; ?>
  <form method="post" class="grid">
    <?= csrf_field() ?>
    <input name="email" type="email" required placeholder="<?= e(t('email')) ?>" autocomplete="username">
    <input name="password" type="password" required placeholder="<?= e(t('password')) ?>" autocomplete="current-password">
    <?php if (!empty($GLOBALS['__turnstile_site'])): ?>
    <script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>
    <div class="cf-turnstile" data-sitekey="<?= e($GLOBALS['__turnstile_site']) ?>"></div>
    <?php endif; ?>
    <div><button type="submit"><?= e(t('login')) ?></button></div>
  </form>
  <?php
  $showErenDev = ($config['default_lang'] ?? '') === 'tr' && ($_SESSION['ui_lang'] ?? '') === 'tr';
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
  <div style="margin-top:1.5rem;padding-top:1.5rem;border-top:1px solid var(--border);text-align:center">
    <a href="<?= e($url) ?>"><img src="<?= e($config['erendev']['button_svg']) ?>" alt="<?= e(t('erendev_login')) ?>" width="240" height="48"></a>
  </div>
  <?php endif; ?>
  <p class="muted text-sm" style="margin-top:1.25rem;display:flex;justify-content:space-between">
    <a href="/forgot-password.php"><?= e(t('forgot_password')) ?></a>
    <a href="/register.php"><?= e(t('register')) ?></a>
  </p>
</div>
PHP

  cat > "$APP_DIR/views/register.php" <<'PHP'
<?php /* @var string $error */ $config = $GLOBALS['__config']; ?>
<div class="glass card" style="max-width:440px;margin:2rem auto;animation:fadeIn .3s ease">
  <h1 style="margin:0 0 1.25rem;font-size:1.5rem"><?= e(t('register')) ?></h1>
  <?php if (!empty($error)): ?><div class="flash flash-err"><?= e($error) ?></div><?php endif; ?>
  <form method="post" class="grid">
    <?= csrf_field() ?>
    <input name="username" required minlength="3" maxlength="32" pattern="[A-Za-z0-9_\-]{3,32}" placeholder="<?= e(t('username')) ?>">
    <input name="email" type="email" required placeholder="<?= e(t('email')) ?>">
    <input name="password" type="password" required minlength="10" placeholder="<?= e(t('password')) ?>">
    <input name="hp" type="text" tabindex="-1" autocomplete="off" style="display:none">
    <?php if (!empty($GLOBALS['__turnstile_site'])): ?>
    <script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>
    <div class="cf-turnstile" data-sitekey="<?= e($GLOBALS['__turnstile_site']) ?>"></div>
    <?php endif; ?>
    <div><button type="submit"><?= e(t('register')) ?></button></div>
  </form>
  <?php
  $showErenDev = ($config['default_lang'] ?? '') === 'tr' && ($_SESSION['ui_lang'] ?? '') === 'tr';
  if ($showErenDev): ?>
    <div style="margin-top:1.5rem;padding-top:1.5rem;border-top:1px solid var(--border);text-align:center">
      <a href="/login.php"><img src="<?= e($config['erendev']['button_svg']) ?>" alt="<?= e(t('erendev_login')) ?>" style="height:48px"></a>
    </div>
  <?php endif; ?>
  <p class="muted text-sm" style="margin-top:1.25rem;text-align:center">
    <?= e(t('login')) ?>? <a href="/login.php"><?= e(t('login')) ?></a>
  </p>
</div>
PHP

  cat > "$APP_DIR/views/forgot-password.php" <<'PHP'
<?php /* @var string $error @var bool $sent */ ?>
<div class="glass card" style="max-width:440px;margin:2rem auto">
  <h1 style="margin:0 0 1.25rem;font-size:1.5rem"><?= e(t('forgot_password')) ?></h1>
  <?php if (!empty($error)): ?><div class="flash flash-err"><?= e($error) ?></div><?php endif; ?>
  <?php if (!empty($sent)): ?>
    <div class="flash flash-ok"><?= e(t('reset_link_sent')) ?></div>
  <?php else: ?>
    <form method="post" class="grid">
      <?= csrf_field() ?>
      <input name="email" type="email" required placeholder="<?= e(t('email')) ?>">
      <div><button type="submit"><?= e(t('reset_password')) ?></button></div>
    </form>
  <?php endif; ?>
  <p class="muted text-sm" style="margin-top:1.25rem;text-align:center"><a href="/login.php">← <?= e(t('login')) ?></a></p>
</div>
PHP

  cat > "$APP_DIR/views/reset-password.php" <<'PHP'
<?php /* @var string $error @var string $token */ ?>
<div class="glass card" style="max-width:440px;margin:2rem auto">
  <h1 style="margin:0 0 1.25rem;font-size:1.5rem"><?= e(t('reset_password')) ?></h1>
  <?php if (!empty($error)): ?><div class="flash flash-err"><?= e($error) ?></div><?php endif; ?>
  <form method="post" class="grid">
    <?= csrf_field() ?>
    <input type="hidden" name="token" value="<?= e($token) ?>">
    <input name="password" type="password" required minlength="10" placeholder="<?= e(t('new_password')) ?>">
    <input name="password2" type="password" required minlength="10" placeholder="<?= e(t('confirm_password')) ?>">
    <div><button type="submit"><?= e(t('reset_password')) ?></button></div>
  </form>
</div>
PHP

  cat > "$APP_DIR/views/search.php" <<'PHP'
<?php /* @var string $q @var array $result @var array $cats */ $lc = $_SESSION['ui_lang'] ?? 'en'; ?>
<div class="glass card" style="margin-bottom:1rem">
  <h1 style="margin:0 0 1rem;font-size:1.5rem"><?= e(t('search')) ?></h1>
  <form method="get" action="/search.php" class="flex flex-wrap" style="gap:.5rem">
    <input name="q" value="<?= e($q) ?>" placeholder="<?= e(t('search_placeholder')) ?>" style="flex:1;min-width:200px">
    <select name="cat" style="width:auto;max-width:180px">
      <option value="">— <?= e(t('categories')) ?> —</option>
      <?php foreach ($cats as $c): ?>
        <option value="<?= (int)$c['id'] ?>" <?= (($_GET['cat'] ?? '') == $c['id']) ? 'selected' : '' ?>><?= e(cat_name($c, $lc)) ?></option>
      <?php endforeach; ?>
    </select>
    <input name="author" placeholder="<?= e(t('username')) ?>" value="<?= e($_GET['author'] ?? '') ?>" style="width:140px">
    <button type="submit"><?= e(t('search')) ?></button>
  </form>
</div>
<?php if ($q !== ''): ?>
<div class="glass">
  <?php if (empty($result['rows'])): ?>
    <div class="card muted" style="text-align:center"><?= e(t('no_results')) ?></div>
  <?php else: ?>
    <div class="card" style="padding-bottom:0"><strong><?= (int)$result['total'] ?> <?= e(t('search_results')) ?></strong></div>
    <?php foreach ($result['rows'] as $r): ?>
      <div class="topic-row" style="display:block">
        <a href="/topic.php?id=<?= (int)$r['topic_id'] ?>" style="font-weight:600;font-size:1rem"><?= e($r['topic_title']) ?></a>
        <div class="meta" style="margin-top:.35rem;color:var(--fg-muted);font-size:.82rem">@<?= e($r['username']) ?></div>
        <p style="margin:.5rem 0 0"><?= str_replace([chr(2), chr(3)], ['<mark>', '</mark>'], e($r['snippet'])) ?></p>
      </div>
    <?php endforeach; ?>
  <?php endif; ?>
</div>
<?php endif; ?>
PHP

  cat > "$APP_DIR/views/notifications.php" <<'PHP'
<?php /* @var array $items */ ?>
<div class="flex" style="justify-content:space-between;margin-bottom:1rem;flex-wrap:wrap">
  <h1 style="margin:0;font-size:1.5rem"><?= e(t('notifications')) ?></h1>
  <form method="post" action="/notifications.php" style="margin:0"><?= csrf_field() ?><input type="hidden" name="action" value="mark_all"><button class="btn-ghost btn btn-sm" type="submit"><?= e(t('mark_all_read')) ?></button></form>
</div>
<div class="glass">
  <?php if (empty($items)): ?>
    <div class="card muted" style="text-align:center"><?= e(t('no_notifications')) ?></div>
  <?php else: foreach ($items as $n): ?>
    <div class="topic-row" style="opacity:<?= $n['read_at'] ? '0.6' : '1' ?>">
      <div class="info">
        <div class="title">
          <span class="pill pill-accent"><?= e($n['kind']) ?></span>
          <?php if ($n['actor']): ?><span class="muted">@<?= e($n['actor']) ?></span><?php endif; ?>
        </div>
        <?php if ($n['snippet']): ?><p class="muted" style="margin:.35rem 0 0;font-size:.85rem"><?= e($n['snippet']) ?></p><?php endif; ?>
        <div class="meta"><span><?= time_ago((int)$n['created_at']) ?></span></div>
      </div>
      <?php if ($n['topic_id']): ?><a href="/topic.php?id=<?= (int)$n['topic_id'] ?>" class="btn btn-sm">→</a><?php endif; ?>
    </div>
  <?php endforeach; endif; ?>
</div>
PHP

  cat > "$APP_DIR/views/settings.php" <<'PHP'
<?php /* @var array $user @var string $error */ ?>
<div class="glass card" style="max-width:560px;margin:2rem auto;animation:fadeIn .3s">
  <h1 style="margin:0 0 1.25rem;font-size:1.5rem"><?= e(t('settings')) ?></h1>
  <?php if (!empty($error)): ?><div class="flash flash-err"><?= e($error) ?></div><?php endif; ?>
  <form method="post" action="/settings.php" class="grid">
    <?= csrf_field() ?>
    <input type="hidden" name="action" value="profile">
    <label class="field"><span><?= e(t('bio')) ?></span>
      <textarea name="bio" rows="3" maxlength="500"><?= e($user['bio'] ?? '') ?></textarea>
    </label>
    <label class="field"><span><?= e(t('theme')) ?></span>
      <select name="theme">
        <?php foreach ($GLOBALS['__config']['themes'] as $th): ?>
          <option value="<?= e($th) ?>" <?= ($user['theme'] ?? 'dark') === $th ? 'selected' : '' ?>><?= e($th) ?></option>
        <?php endforeach; ?>
      </select>
    </label>
    <label class="field"><span><?= e(t('accent')) ?></span>
      <select name="accent">
        <?php foreach ($GLOBALS['__config']['accents'] as $ac): ?>
          <option value="<?= e($ac) ?>" <?= ($user['accent'] ?? 'indigo') === $ac ? 'selected' : '' ?>><?= e($ac) ?></option>
        <?php endforeach; ?>
      </select>
    </label>
    <label class="field"><span><?= e(t('avatar_color')) ?></span>
      <input type="color" name="avatar_color" value="<?= e($user['avatar_color'] ?? '#6366f1') ?>" style="height:44px;padding:4px">
    </label>
    <label class="flex"><input type="checkbox" name="notify_mentions" <?= ($user['notify_mentions'] ?? 1) ? 'checked' : '' ?>> <span><?= e(t('notify_mentions')) ?></span></label>
    <label class="flex"><input type="checkbox" name="notify_replies" <?= ($user['notify_replies'] ?? 1) ? 'checked' : '' ?>> <span><?= e(t('notify_replies')) ?></span></label>
    <label class="flex"><input type="checkbox" name="notify_reactions" <?= ($user['notify_reactions'] ?? 1) ? 'checked' : '' ?>> <span><?= e(t('notify_reactions')) ?></span></label>
    <label class="flex"><input type="checkbox" name="notify_digest" <?= ($user['notify_digest'] ?? 0) ? 'checked' : '' ?>> <span><?= e(t('notify_digest')) ?></span></label>
    <div><button type="submit"><?= e(t('save')) ?></button></div>
  </form>
</div>

<div class="glass card" style="max-width:560px;margin:1rem auto">
  <h2 class="sec-title"><?= e(t('password_change')) ?></h2>
  <form method="post" action="/settings.php" class="grid">
    <?= csrf_field() ?>
    <input type="hidden" name="action" value="password">
    <input name="current_password" type="password" required placeholder="<?= e(t('current_password')) ?>">
    <input name="new_password" type="password" required minlength="10" placeholder="<?= e(t('new_password')) ?>">
    <input name="confirm_password" type="password" required minlength="10" placeholder="<?= e(t('confirm_password')) ?>">
    <div><button type="submit"><?= e(t('password_change')) ?></button></div>
  </form>
</div>
PHP

  cat > "$APP_DIR/views/user.php" <<'PHP'
<?php /* @var array $profile @var array $topics @var array $posts */ $me = auth_user(); ?>
<div class="glass card" style="margin-bottom:1.25rem;display:flex;gap:1.5rem;align-items:center;flex-wrap:wrap">
  <div class="avatar-lg" style="background:linear-gradient(135deg,<?= e($profile['avatar_color']) ?>,<?= e($profile['avatar_color']) ?>99)"><?= e(mb_strtoupper(mb_substr($profile['username'], 0, 1))) ?></div>
  <div style="flex:1;min-width:200px">
    <h1 style="margin:0 0 .35rem;font-size:1.75rem">@<?= e($profile['username']) ?><?= verified_badge((int)$profile['is_verified']) ?></h1>
    <?php if ($profile['bio']): ?><p class="muted" style="margin:0 0 .5rem"><?= e($profile['bio']) ?></p><?php endif; ?>
    <div class="flex flex-wrap muted" style="font-size:.85rem">
      <span class="pill"><?= e($profile['role']) ?></span>
      <?php if ((int)$profile['banned']): ?><span class="pill pill-danger"><?= e(t('banned')) ?></span><?php endif; ?>
      <span><?= e(t('joined')) ?>: <?= date('Y-m-d', (int)$profile['created_at']) ?></span>
      <span><?= e(t('last_seen')) ?>: <?= time_ago((int)($profile['last_seen_at'] ?? $profile['created_at'])) ?></span>
    </div>
  </div>
  <?php if (is_admin($me) && (int)$profile['id'] !== (int)$me['id']): ?>
    <form method="post" action="/mod.php" style="margin:0" data-confirm="<?= e(t('delete_confirm')) ?>">
      <?= csrf_field() ?>
      <input type="hidden" name="action" value="ban_user">
      <input type="hidden" name="user_id" value="<?= (int)$profile['id'] ?>">
      <input type="hidden" name="state" value="<?= (int)$profile['banned'] ? 0 : 1 ?>">
      <?php if (!(int)$profile['banned']): ?>
        <button class="btn-danger btn btn-sm" type="submit">🚫 <?= e(t('ban_user')) ?></button>
      <?php else: ?>
        <button class="btn-ghost btn btn-sm" type="submit"><?= e(t('unban_user')) ?></button>
      <?php endif; ?>
    </form>
  <?php endif; ?>
</div>

<h2 class="sec-title"><?= e(t('topics')) ?> (<?= count($topics) ?>)</h2>
<div class="glass" style="margin-bottom:1.5rem">
  <?php if (empty($topics)): ?><div class="card muted" style="text-align:center">—</div>
  <?php else: foreach ($topics as $tp): ?>
    <a href="/topic.php?id=<?= (int)$tp['id'] ?>" class="topic-row" style="display:block">
      <div class="title"><?= e($tp['title']) ?></div>
      <div class="meta"><span><?= e($tp['cat_name']) ?></span><span>· <?= time_ago((int)$tp['updated_at']) ?></span></div>
    </a>
  <?php endforeach; endif; ?>
</div>

<h2 class="sec-title"><?= e(t('posts')) ?> (<?= count($posts) ?>)</h2>
<div class="glass">
  <?php if (empty($posts)): ?><div class="card muted" style="text-align:center">—</div>
  <?php else: foreach ($posts as $p): ?>
    <a href="/topic.php?id=<?= (int)$p['topic_id'] ?>" class="topic-row" style="display:block">
      <div class="title"><?= e($p['topic_title']) ?></div>
      <div class="meta"><span><?= time_ago((int)$p['created_at']) ?></span></div>
      <p style="margin:.5rem 0 0;color:var(--fg-muted);font-size:.9rem"><?= e(mb_substr($p['body'], 0, 140)) ?><?= mb_strlen($p['body']) > 140 ? '…' : '' ?></p>
    </a>
  <?php endforeach; endif; ?>
</div>
PHP

  cat > "$APP_DIR/views/stats.php" <<'PHP'
<?php /* @var array $stats @var array $topUsers */ ?>
<div class="hero" style="padding:1.5rem 1rem"><h1 style="font-size:2rem"><?= e(t('stats')) ?></h1></div>
<div class="stat-grid">
  <div class="stat-card"><div class="num"><?= (int)$stats['topics'] ?></div><div class="label"><?= e(t('total_topics')) ?></div></div>
  <div class="stat-card"><div class="num"><?= (int)$stats['posts'] ?></div><div class="label"><?= e(t('total_posts')) ?></div></div>
  <div class="stat-card"><div class="num"><?= (int)$stats['users'] ?></div><div class="label"><?= e(t('total_users')) ?></div></div>
  <div class="stat-card"><div class="num"><?= (int)$stats['online'] ?></div><div class="label"><?= e(t('online_users')) ?></div></div>
  <div class="stat-card"><div class="num"><?= (int)$stats['members_online'] ?></div><div class="label"><?= e(t('members')) ?></div></div>
</div>
<?php if ($stats['newest']): ?>
<div class="glass card" style="margin-bottom:1rem">
  <strong><?= e(t('members')) ?>:</strong> <a href="/user.php?u=<?= e($stats['newest']['username']) ?>">@<?= e($stats['newest']['username']) ?></a>
  <span class="muted" style="margin-left:.5rem">· <?= time_ago((int)$stats['newest']['created_at']) ?></span>
</div>
<?php endif; ?>
<h2 class="sec-title"><?= e(t('popular')) ?></h2>
<div class="glass">
  <?php foreach ($topUsers as $tu): ?>
    <a href="/user.php?u=<?= e($tu['username']) ?>" class="topic-row">
      <?= user_avatar($tu['username'], $tu['avatar_color'] ?? '#6366f1', 32) ?>
      <div class="info"><div class="title">@<?= e($tu['username']) ?></div></div>
      <div class="counts"><div class="c"><strong><?= (int)$tu['cnt'] ?></strong><?= e(t('posts')) ?></div></div>
    </a>
  <?php endforeach; ?>
</div>
PHP

  cat > "$APP_DIR/views/activity.php" <<'PHP'
<?php /* @var array $topics @var array $posts */ ?>
<div class="hero" style="padding:1.5rem 1rem"><h1 style="font-size:2rem"><?= e(t('activity')) ?></h1></div>
<h2 class="sec-title"><?= e(t('recent_topics')) ?></h2>
<div class="glass" style="margin-bottom:1.5rem">
  <?php foreach ($topics as $tp): ?>
    <a href="/topic.php?id=<?= (int)$tp['id'] ?>" class="topic-row">
      <?= user_avatar($tp['username'], '#6366f1', 32) ?>
      <div class="info">
        <div class="title"><?= e($tp['title']) ?></div>
        <div class="meta"><span>@<?= e($tp['username']) ?></span><span>· <?= time_ago((int)$tp['updated_at']) ?></span></div>
      </div>
    </a>
  <?php endforeach; ?>
</div>
<h2 class="sec-title"><?= e(t('latest_posts')) ?></h2>
<div class="glass">
  <?php foreach ($posts as $p): ?>
    <a href="/topic.php?id=<?= (int)$p['topic_id'] ?>" class="topic-row" style="display:block">
      <?= user_avatar($p['username'], '#6366f1', 32) ?>
      <div class="info">
        <div class="title"><?= e($p['topic_title']) ?></div>
        <div class="meta"><span>@<?= e($p['username']) ?></span><span>· <?= time_ago((int)$p['created_at']) ?></span></div>
        <p style="margin:.5rem 0 0;color:var(--fg-muted);font-size:.9rem"><?= e(mb_substr($p['body'], 0, 140)) ?><?= mb_strlen($p['body']) > 140 ? '…' : '' ?></p>
      </div>
    </a>
  <?php endforeach; ?>
</div>
PHP

  cat > "$APP_DIR/views/admin.php" <<'PHP'
<?php
/* @var string $tab @var array $users @var array $roles @var array $cats @var array $catTags
   @var ?array $editCat @var array $audit @var string $appName @var string $appTagline
   @var array $providers @var array $profiles @var array $catsAll @var array $adapters
   @var ?array $editProfile @var string $aiEnabled */
$tabField = '<input type="hidden" name="tab" value="' . e($tab) . '">';
$tabs = ['general' => 'tab_general', 'ai' => 'tab_ai', 'turnstile' => 'tab_turnstile',
         'users' => 'tab_users', 'categories' => 'tab_categories', 'audit' => 'tab_audit'];
?>
<div style="margin-bottom:.75rem"><h1 style="margin:0;font-size:1.75rem"><?= e(t('admin_panel')) ?></h1></div>
<nav class="tabs">
  <?php foreach ($tabs as $k => $lbl): ?>
    <a href="/admin.php?tab=<?= e($k) ?>" class="<?= $tab === $k ? 'on' : '' ?>"><?= e(t($lbl)) ?></a>
  <?php endforeach; ?>
</nav>

<?php if ($tab === 'general'): ?>
<div class="glass card">
  <h2 class="sec-title"><?= e(t('admin_settings')) ?></h2>
  <form method="post" action="/admin.php" class="grid">
    <?= csrf_field() ?><input type="hidden" name="action" value="save_settings"><?= $tabField ?>
    <label class="field"><span><?= e(t('site_name')) ?></span><input name="app_name" value="<?= e($appName) ?>" required maxlength="60"></label>
    <label class="field"><span><?= e(t('site_tagline')) ?></span><input name="app_tagline" value="<?= e($appTagline) ?>" maxlength="160"></label>
    <div><button type="submit"><?= e(t('save')) ?></button></div>
  </form>
</div>

<?php elseif ($tab === 'ai'): ?>
<div class="glass card" style="margin-bottom:1.25rem">
  <h2 class="sec-title"><?= e(t('tab_ai')) ?></h2>
  <form method="post" action="/admin.php" class="flex flex-wrap">
    <?= csrf_field() ?><input type="hidden" name="action" value="save_ai_global"><?= $tabField ?>
    <label class="flex"><input type="checkbox" name="ai_enabled" value="1" <?= $aiEnabled === '1' ? 'checked' : '' ?>> <span><?= e(t('ai_global')) ?></span></label>
    <button type="submit"><?= e(t('save')) ?></button>
  </form>
  <p class="hint"><?= e(t('ai_hint')) ?></p>
  <p class="hint"><?= e(t('ai_key_hint')) ?></p>
</div>

<div class="glass card" style="margin-bottom:1.25rem">
  <h2 class="sec-title"><?= e(t('ai_providers')) ?></h2>
  <div class="grid">
    <?php foreach ($providers as $pv): ?>
      <form method="post" action="/admin.php" class="grid" style="border:1px solid var(--border);border-radius:.75rem;padding:1rem">
        <?= csrf_field() ?><input type="hidden" name="action" value="save_provider"><?= $tabField ?>
        <input type="hidden" name="provider_id" value="<?= (int)$pv['id'] ?>">
        <div class="flex flex-wrap" style="justify-content:space-between">
          <strong><?= e($pv['name']) ?> <span class="pill"><?= e($adapters[$pv['adapter']] ?? $pv['adapter']) ?></span></strong>
          <label class="flex"><input type="checkbox" name="enabled" value="1" <?= (int)$pv['enabled'] ? 'checked' : '' ?>> <span><?= e(t('ai_enabled')) ?></span></label>
        </div>
        <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(220px,1fr))">
          <label class="field"><span><?= e(t('ai_base_url')) ?></span><input name="base_url" value="<?= e($pv['base_url']) ?>"></label>
          <label class="field"><span><?= e(t('ai_default_model')) ?></span><input name="default_model" value="<?= e($pv['default_model']) ?>"></label>
          <label class="field"><span><?= e(t('ai_api_key')) ?></span>
            <input name="api_key" type="password" autocomplete="new-password"
                   placeholder="<?= $pv['api_key_enc'] !== '' ? e(t('ai_key_saved')) : e(t('ai_no_key_needed')) ?>">
          </label>
        </div>
        <div><button type="submit"><?= e(t('save')) ?></button></div>
      </form>
    <?php endforeach; ?>
  </div>

  <details style="margin-top:1.25rem">
    <summary style="cursor:pointer;font-weight:600;color:var(--accent-400)">+ <?= e(t('ai_add_provider')) ?></summary>
    <form method="post" action="/admin.php" class="grid" style="margin-top:1rem">
      <?= csrf_field() ?><input type="hidden" name="action" value="add_provider"><?= $tabField ?>
      <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(200px,1fr))">
        <input name="name" placeholder="<?= e(t('ai_provider')) ?>" required maxlength="60">
        <input name="slug" placeholder="slug" required pattern="[a-zA-Z0-9\-]{2,32}">
        <select name="adapter">
          <?php foreach ($adapters as $k => $lbl): ?><option value="<?= e($k) ?>"><?= e($lbl) ?></option><?php endforeach; ?>
        </select>
        <input name="base_url" placeholder="https://..." required>
        <input name="default_model" placeholder="<?= e(t('ai_model')) ?>" maxlength="100">
      </div>
      <div><button type="submit"><?= e(t('save')) ?></button></div>
    </form>
  </details>
</div>

<div class="glass card" style="margin-bottom:1.25rem">
  <h2 class="sec-title"><?= e(t('ai_profiles')) ?></h2>
  <?php if (empty($profiles)): ?>
    <p class="muted"><?= e(t('no_results')) ?></p>
  <?php else: ?>
  <div style="overflow-x:auto;margin-bottom:1.25rem">
    <table>
      <thead><tr><th><?= e(t('ai_profile_name')) ?></th><th><?= e(t('ai_provider')) ?></th><th><?= e(t('ai_model')) ?></th><th><?= e(t('ai_category')) ?></th><th><?= e(t('status')) ?></th><th></th></tr></thead>
      <tbody>
        <?php foreach ($profiles as $pf): ?>
          <tr>
            <td><strong><?= e($pf['name']) ?></strong></td>
            <td><?= e($pf['provider_name']) ?></td>
            <td><code><?= e($pf['model'] !== '' ? $pf['model'] : $pf['default_model']) ?></code></td>
            <td><?= e($pf['cat_name'] ?? t('all')) ?></td>
            <td><?= (int)$pf['enabled'] ? '✓' : '—' ?></td>
            <td>
              <div class="flex" style="gap:.35rem">
                <a href="/admin.php?tab=ai&amp;edit_profile=<?= (int)$pf['id'] ?>" class="btn btn-ghost btn-sm"><?= e(t('edit')) ?></a>
                <form method="post" action="/admin.php" style="margin:0" data-confirm="<?= e(t('delete_confirm')) ?>">
                  <?= csrf_field() ?><input type="hidden" name="action" value="delete_profile"><?= $tabField ?>
                  <input type="hidden" name="profile_id" value="<?= (int)$pf['id'] ?>">
                  <button class="btn-danger btn btn-sm" type="submit">🗑</button>
                </form>
              </div>
            </td>
          </tr>
        <?php endforeach; ?>
      </tbody>
    </table>
  </div>
  <?php endif; ?>

  <h3 style="margin:0 0 .75rem;font-size:1rem"><?= e($editProfile ? t('ai_edit_profile') : t('ai_add_profile')) ?></h3>
  <form method="post" action="/admin.php" class="grid">
    <?= csrf_field() ?><input type="hidden" name="action" value="save_profile"><?= $tabField ?>
    <input type="hidden" name="profile_id" value="<?= (int)($editProfile['id'] ?? 0) ?>">
    <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(200px,1fr))">
      <label class="field"><span><?= e(t('ai_profile_name')) ?></span>
        <input name="name" required maxlength="60" value="<?= e($editProfile['name'] ?? '') ?>"></label>
      <label class="field"><span><?= e(t('ai_provider')) ?></span>
        <select name="provider_id" required>
          <?php foreach ($providers as $pv): ?>
            <option value="<?= (int)$pv['id'] ?>" <?= (int)($editProfile['provider_id'] ?? 0) === (int)$pv['id'] ? 'selected' : '' ?>><?= e($pv['name']) ?></option>
          <?php endforeach; ?>
        </select></label>
      <label class="field"><span><?= e(t('ai_model')) ?> <small>(<?= e(t('ai_model_hint')) ?>)</small></span>
        <input name="model" maxlength="100" value="<?= e($editProfile['model'] ?? '') ?>"></label>
      <label class="field"><span><?= e(t('ai_category')) ?></span>
        <select name="category_id">
          <option value="">— <?= e(t('all')) ?> —</option>
          <?php foreach ($catsAll as $c): ?>
            <option value="<?= (int)$c['id'] ?>" <?= (int)($editProfile['category_id'] ?? 0) === (int)$c['id'] ? 'selected' : '' ?>><?= e($c['name_en']) ?> / <?= e($c['name_tr']) ?></option>
          <?php endforeach; ?>
        </select></label>
    </div>
    <label class="field"><span><?= e(t('ai_system_prompt')) ?></span>
      <textarea name="system_prompt" rows="4" required maxlength="4000"><?= e($editProfile['system_prompt'] ?? '') ?></textarea></label>
    <label class="flex"><input type="checkbox" name="enabled" value="1" <?= !isset($editProfile) || (int)($editProfile['enabled'] ?? 0) ? 'checked' : '' ?>> <span><?= e(t('ai_enabled')) ?></span></label>
    <div class="flex"><button type="submit"><?= e(t('save')) ?></button>
      <?php if ($editProfile): ?><a href="/admin.php?tab=ai" class="btn btn-ghost"><?= e(t('back')) ?></a><?php endif; ?></div>
  </form>
</div>

<?php elseif ($tab === 'turnstile'): ?>
<div class="glass card">
  <h2 class="sec-title">Cloudflare Turnstile</h2>
  <form method="post" action="/admin.php" class="grid">
    <?= csrf_field() ?><input type="hidden" name="action" value="save_turnstile"><?= $tabField ?>
    <label class="flex"><input type="checkbox" name="ts_enabled" value="1" <?= settings_get($db, 'turnstile_enabled', '0') === '1' ? 'checked' : '' ?>> <span><?= e(t('ts_enabled')) ?></span></label>
    <label class="field"><span><?= e(t('ts_site_key')) ?></span><input name="ts_site" maxlength="100" value="<?= e(settings_get($db, 'turnstile_site_key', '')) ?>"></label>
    <label class="field"><span><?= e(t('ts_secret')) ?></span>
      <input name="ts_secret" type="password" autocomplete="new-password"
             placeholder="<?= settings_get($db, 'turnstile_secret_enc', '') !== '' ? e(t('ts_secret_saved')) : '' ?>">
    </label>
    <div><button type="submit"><?= e(t('save')) ?></button></div>
  </form>
  <p class="hint"><?= e(t('ts_hint')) ?></p>
</div>

<?php elseif ($tab === 'users'): ?>
<div class="glass card" style="margin-bottom:1.25rem">
  <h2 class="sec-title"><?= e(t('tab_users')) ?></h2>
  <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:1.25rem">
    <form method="post" action="/admin.php" class="grid">
      <?= csrf_field() ?><input type="hidden" name="action" value="set_verified"><?= $tabField ?>
      <strong><?= e(t('verify_user')) ?></strong>
      <input name="username" required placeholder="<?= e(t('username')) ?>">
      <label class="flex"><input type="checkbox" name="verified" value="1"> <span><?= e(t('verified')) ?></span></label>
      <div><button type="submit"><?= e(t('save')) ?></button></div>
    </form>
    <form method="post" action="/admin.php" class="grid">
      <?= csrf_field() ?><input type="hidden" name="action" value="assign_role"><?= $tabField ?>
      <strong><?= e(t('assign_role')) ?></strong>
      <input name="username" required placeholder="<?= e(t('username')) ?>">
      <select name="role_id">
        <option value="0"><?= e(t('no_role')) ?></option>
        <?php foreach ($roles as $r): ?><option value="<?= (int)$r['id'] ?>"><?= e($r['name']) ?></option><?php endforeach; ?>
      </select>
      <div><button type="submit"><?= e(t('assign')) ?></button></div>
    </form>
    <form method="post" action="/admin.php" class="grid">
      <?= csrf_field() ?><input type="hidden" name="action" value="create_role"><?= $tabField ?>
      <strong><?= e(t('create_role')) ?></strong>
      <input name="role_name" maxlength="32" required placeholder="<?= e(t('role_name')) ?>">
      <div class="flex flex-wrap">
        <input name="role_color" type="color" value="#6366f1" style="width:70px;padding:4px">
        <input name="role_power" type="number" min="0" max="99" value="0" style="width:110px" title="<?= e(t('power_level')) ?>">
      </div>
      <div><button type="submit"><?= e(t('add_category')) ?></button></div>
    </form>
  </div>
  <p class="hint"><?= e(t('role_hint')) ?></p>

  <h3 style="margin:1.25rem 0 .5rem;font-size:1rem"><?= e(t('roles_existing')) ?></h3>
  <div class="flex flex-wrap" style="gap:.5rem">
    <?php foreach ($roles as $r): ?>
      <span class="pill" style="background:<?= e($r['color_hex']) ?>;color:#fff"><?= e($r['name']) ?> (<?= (int)$r['power_level'] ?>)</span>
      <form method="post" action="/admin.php" style="margin:0" data-confirm="<?= e(t('delete_confirm')) ?>">
        <?= csrf_field() ?><input type="hidden" name="action" value="delete_role"><?= $tabField ?>
        <input type="hidden" name="role_id" value="<?= (int)$r['id'] ?>">
        <button class="btn-danger btn btn-sm" type="submit">🗑</button>
      </form>
    <?php endforeach; ?>
  </div>
</div>

<div class="glass card" style="margin-bottom:1.25rem">
  <form method="post" action="/admin.php" class="flex flex-wrap">
    <?= csrf_field() ?><input type="hidden" name="action" value="bulk_role"><?= $tabField ?>
    <input name="ids" placeholder="<?= e(t('bulk_ids')) ?>" style="flex:1;min-width:160px">
    <select name="role" style="width:auto"><option>member</option><option>moderator</option><option>admin</option></select>
    <button type="submit" class="btn-sm"><?= e(t('set_role')) ?></button>
  </form>
</div>

<div class="glass" style="overflow-x:auto">
  <table>
    <thead><tr><th>ID</th><th><?= e(t('username')) ?></th><th><?= e(t('email')) ?></th><th><?= e(t('roles')) ?></th><th><?= e(t('status')) ?></th></tr></thead>
    <tbody>
      <?php foreach ($users as $usr): ?>
        <tr>
          <td><?= (int)$usr['id'] ?></td>
          <td><a href="/user.php?u=<?= e($usr['username']) ?>">@<?= e($usr['username']) ?></a><?= verified_badge((int)$usr['is_verified']) ?></td>
          <td class="muted"><?= e($usr['email']) ?></td>
          <td><span class="pill"><?= e($usr['role']) ?></span></td>
          <td><?php if ((int)$usr['banned']): ?><span class="pill pill-danger"><?= e(t('banned')) ?></span><?php else: ?>✓<?php endif; ?></td>
        </tr>
      <?php endforeach; ?>
    </tbody>
  </table>
</div>

<?php elseif ($tab === 'categories'): ?>
<?php if ($editCat): ?>
<div class="glass card" style="margin-bottom:1.25rem">
  <h2 class="sec-title"><?= e(t('edit_category')) ?> #<?= (int)$editCat['id'] ?></h2>
  <form method="post" action="/admin.php" class="grid">
    <?= csrf_field() ?><input type="hidden" name="action" value="edit_category"><?= $tabField ?>
    <input type="hidden" name="id" value="<?= (int)$editCat['id'] ?>">
    <div class="flex flex-wrap" style="gap:.5rem">
      <input name="slug" value="<?= e($editCat['slug']) ?>" required pattern="[a-z0-9\-]+" style="flex:1;min-width:140px">
      <input name="icon" value="<?= e($editCat['icon']) ?>" maxlength="4" style="width:80px">
      <input name="position" type="number" value="<?= (int)$editCat['position'] ?>" style="width:100px">
    </div>
    <div class="flex flex-wrap" style="gap:.5rem">
      <input name="name_tr" value="<?= e($editCat['name_tr']) ?>" placeholder="TR" required style="flex:1;min-width:120px">
      <input name="name_en" value="<?= e($editCat['name_en']) ?>" placeholder="EN" required style="flex:1;min-width:120px">
      <input name="name_fr" value="<?= e($editCat['name_fr'] ?? '') ?>" placeholder="FR" style="flex:1;min-width:100px">
      <input name="name_de" value="<?= e($editCat['name_de'] ?? '') ?>" placeholder="DE" style="flex:1;min-width:100px">
      <input name="name_es" value="<?= e($editCat['name_es'] ?? '') ?>" placeholder="ES" style="flex:1;min-width:100px">
      <input name="name_ar" value="<?= e($editCat['name_ar'] ?? '') ?>" placeholder="AR" style="flex:1;min-width:100px">
    </div>
    <input name="description_tr" value="<?= e($editCat['description_tr'] ?? '') ?>" placeholder="TR description">
    <input name="description_en" value="<?= e($editCat['description_en'] ?? '') ?>" placeholder="EN description">
    <div class="flex"><button type="submit"><?= e(t('save')) ?></button>
      <a href="/admin.php?tab=categories" class="btn btn-ghost"><?= e(t('back')) ?></a></div>
  </form>
</div>
<?php endif; ?>

<div class="glass card" style="margin-bottom:1.25rem">
  <h2 class="sec-title"><?= e(t('admin_categories')) ?></h2>
  <div style="overflow-x:auto">
  <table>
    <thead><tr><th>ID</th><th><?= e(t('icon')) ?></th><th>EN</th><th>TR</th><th><?= e(t('slug')) ?></th><th><?= e(t('position')) ?></th><th></th></tr></thead>
    <tbody>
      <?php foreach ($cats as $c): ?>
        <tr>
          <td><?= (int)$c['id'] ?></td>
          <td style="font-size:1.3rem"><?= e($c['icon']) ?></td>
          <td><a href="/category.php?slug=<?= e($c['slug']) ?>"><?= e($c['name_en']) ?></a></td>
          <td><?= e($c['name_tr']) ?></td>
          <td><code><?= e($c['slug']) ?></code></td>
          <td><?= (int)$c['position'] ?></td>
          <td>
            <div class="flex" style="gap:.35rem">
              <a href="/admin.php?tab=categories&amp;edit_cat=<?= (int)$c['id'] ?>" class="btn btn-ghost btn-sm"><?= e(t('edit')) ?></a>
              <form method="post" action="/admin.php" style="margin:0" data-confirm="<?= e(t('delete_confirm')) ?>">
                <?= csrf_field() ?><input type="hidden" name="action" value="delete_category"><?= $tabField ?>
                <input type="hidden" name="id" value="<?= (int)$c['id'] ?>">
                <button class="btn-danger btn btn-sm" type="submit">🗑</button>
              </form>
            </div>
          </td>
        </tr>
      <?php endforeach; ?>
    </tbody>
  </table>
  </div>
</div>

<div class="glass card" style="margin-bottom:1.25rem">
  <h2 class="sec-title"><?= e(t('category_tags')) ?></h2>
  <?php foreach ($cats as $c): ?>
    <form method="post" action="/admin.php" class="flex flex-wrap" style="margin-bottom:.6rem">
      <?= csrf_field() ?><input type="hidden" name="action" value="set_category_tags"><?= $tabField ?>
      <input type="hidden" name="category_id" value="<?= (int)$c['id'] ?>">
      <strong style="min-width:150px"><?= e($c['icon']) ?> <?= e($c['name_en']) ?></strong>
      <input name="tags" value="<?= e(implode(', ', $catTags[(int)$c['id']] ?? [])) ?>" placeholder="<?= e(t('tags_placeholder')) ?>" style="flex:1;min-width:200px">
      <button class="btn-ghost btn btn-sm" type="submit"><?= e(t('save')) ?></button>
    </form>
  <?php endforeach; ?>
  <p class="hint"><?= e(t('tags_hint')) ?></p>
</div>

<div class="glass card">
  <details>
    <summary style="cursor:pointer;font-weight:600;color:var(--accent-400)">+ <?= e(t('add_category')) ?></summary>
    <form method="post" action="/admin.php" class="grid" style="margin-top:1rem">
      <?= csrf_field() ?><input type="hidden" name="action" value="add_category"><?= $tabField ?>
      <div class="flex flex-wrap" style="gap:.5rem">
        <input name="slug" placeholder="<?= e(t('slug')) ?>" required pattern="[a-z0-9\-]+" style="flex:1;min-width:120px">
        <input name="icon" placeholder="💬" maxlength="4" value="💬" style="width:80px">
        <input name="position" type="number" placeholder="<?= e(t('position')) ?>" value="0" style="width:100px">
      </div>
      <div class="flex flex-wrap" style="gap:.5rem">
        <input name="name_tr" placeholder="TR" required style="flex:1;min-width:120px">
        <input name="name_en" placeholder="EN" required style="flex:1;min-width:120px">
      </div>
      <div class="flex flex-wrap" style="gap:.5rem">
        <input name="description_tr" placeholder="TR description" style="flex:1;min-width:200px">
        <input name="description_en" placeholder="EN description" style="flex:1;min-width:200px">
      </div>
      <div><button type="submit"><?= e(t('add_category')) ?></button></div>
    </form>
  </details>
</div>

<?php elseif ($tab === 'audit'): ?>
<div class="glass" style="overflow-x:auto">
  <div class="card" style="padding-bottom:.5rem"><h2 class="sec-title" style="margin:0"><?= e(t('admin_audit')) ?></h2></div>
  <table>
    <thead><tr><th><?= e(t('audit_when')) ?></th><th><?= e(t('actor')) ?></th><th><?= e(t('action')) ?></th></tr></thead>
    <tbody>
      <?php foreach ($audit as $a): ?>
        <tr><td class="muted"><?= date('Y-m-d H:i', (int)$a['ts']) ?></td><td><?= e($a['actor'] ?? '-') ?></td><td><code><?= e($a['action']) ?></code></td></tr>
      <?php endforeach; ?>
    </tbody>
  </table>
</div>
<?php endif; ?>
PHP

  cat > "$APP_DIR/views/404.php" <<'PHP'
<div class="hero">
  <h1 style="font-size:5rem;margin:0">404</h1>
  <p style="margin:1rem 0 2rem"><?= e(t('not_found')) ?></p>
  <a href="/" class="btn">← <?= e(t('home')) ?></a>
</div>
PHP

  chown -R root:root "$APP_DIR/views"
  find "$APP_DIR/views" -type d -exec chmod 0755 {} \;
  find "$APP_DIR/views" -type f -exec chmod 0644 {} \;
  ok "views/"
}

write_public() {
  cat > "$APP_DIR/public/assets/app.js" <<'JS'
document.addEventListener('change', function (e) {
  var el = e.target;
  if (el && el.hasAttribute && el.hasAttribute('data-autosubmit') && el.form) el.form.submit();
});
document.addEventListener('submit', function (e) {
  var msg = e.target && e.target.getAttribute && e.target.getAttribute('data-confirm');
  if (msg !== null && !window.confirm(msg)) e.preventDefault();
});
JS

  cat > "$APP_DIR/public/index.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$lc = $_SESSION['ui_lang'];
$cats = $db->query("SELECT c.*, (SELECT COUNT(*) FROM topics t WHERE t.category_id = c.id) AS n FROM categories c ORDER BY position, id")->fetchAll();
$recent = recent_topics($db, 10);
$stats = forum_stats($db);
$title = t('forum');
ob_start(); require LF_ROOT . '/views/home.php'; $content = ob_get_clean();
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/lang.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
if ($_SERVER['REQUEST_METHOD'] !== 'POST') { http_response_code(405); exit; }
csrf_verify();
$l = $_POST['lang'] ?? '';
if (in_array($l, $config['available_langs'], true)) { $_SESSION['ui_lang'] = $l; }
redirect(safe_next((string)parse_url($_SERVER['HTTP_REFERER'] ?? '/', PHP_URL_PATH)));
PHP

  cat > "$APP_DIR/public/login.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$error = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
  csrf_verify();
  if (!turnstile_ok($db, $config)) {
    $error = t('bot_detected');
  } elseif (!rate_limit($db, 'login', client_ip(), $config['rate_limit']['login_per_10min'], 600)) {
    http_response_code(429); $error = t('too_many_attempts');
  } else {
    $email = filter_var($_POST['email'] ?? '', FILTER_VALIDATE_EMAIL);
    $pass  = (string)($_POST['password'] ?? '');
    if (!$email || $pass === '') {
      $error = t('missing_info');
    } else {
      $st = $db->prepare('SELECT * FROM users WHERE email = ?'); $st->execute([$email]); $u = $st->fetch();
      if ($u && password_verify_safe($pass, $u['password_hash'])) {
        if ((int)$u['banned'] === 1) { $error = t('banned_msg'); }
        else { auth_login($u); redirect(safe_next((string)($_GET['next'] ?? '/'))); }
      } else {
        $error = t('bad_credentials');
      }
    }
  }
}
ob_start(); require LF_ROOT . '/views/login.php'; $content = ob_get_clean();
$title = t('login');
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/register.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$error = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
  csrf_verify();
  if (!empty($_POST['hp'])) { http_response_code(400); exit(t('bot_detected')); }
  if (!turnstile_ok($db, $config)) {
    $error = t('bot_detected');
  } elseif (!rate_limit($db, 'register', client_ip(), $config['rate_limit']['register_per_hr'], 3600)) {
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
        $db->prepare('INSERT INTO users(username, email, password_hash, created_at, last_seen_at) VALUES(?, ?, ?, ?, ?)')
           ->execute([$u, $em, password_hash_safe($p), time(), time()]);
        $row = $db->prepare('SELECT * FROM users WHERE id = ?'); $row->execute([$db->lastInsertId()]);
        auth_login($row->fetch());
        redirect('/');
      } catch (PDOException) {
        $error = t('already_exists');
      }
    }
  }
}
ob_start(); require LF_ROOT . '/views/register.php'; $content = ob_get_clean();
$title = t('register');
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

  cat > "$APP_DIR/public/forgot-password.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$error = ''; $sent = false;
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
  csrf_verify();
  if (!rate_limit($db, 'reset', client_ip(), $config['rate_limit']['reset_per_hr'], 3600)) {
    http_response_code(429); $error = t('too_many_attempts');
  } else {
    $email = filter_var($_POST['email'] ?? '', FILTER_VALIDATE_EMAIL);
    if ($email) {
      $st = $db->prepare('SELECT id FROM users WHERE email = ?');
      $st->execute([$email]); $row = $st->fetch();
      if ($row) {
        $token = generate_reset_token($db, (int)$row['id']);
        $url = $config['base_url'] . '/reset-password.php?token=' . $token;
        send_mail($email, t('reset_password'), t('reset_password') . ":\n\n$url\n\n" . date('Y-m-d H:i'));
      }
    }
    $sent = true;
  }
}
ob_start(); require LF_ROOT . '/views/forgot-password.php'; $content = ob_get_clean();
$title = t('forgot_password');
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/reset-password.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$error = '';
$token = (string)($_GET['token'] ?? $_POST['token'] ?? '');
if ($token === '') { http_response_code(400); $error = t('reset_invalid'); }
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $token !== '') {
  csrf_verify();
  $p1 = (string)($_POST['password']  ?? '');
  $p2 = (string)($_POST['password2'] ?? '');
  if (strlen($p1) < 10) $error = t('weak_password');
  elseif ($p1 !== $p2)  $error = t('password_mismatch');
  else {
    $uid = consume_reset_token($db, $token);
    if (!$uid) $error = t('reset_invalid');
    else {
      $db->prepare('UPDATE users SET password_hash = ? WHERE id = ?')->execute([password_hash_safe($p1), $uid]);
      flash_set('ok', t('reset_complete'));
      redirect('/login.php');
    }
  }
}
ob_start(); require LF_ROOT . '/views/reset-password.php'; $content = ob_get_clean();
$title = t('reset_password');
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/category.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$slug = trim((string)($_GET['slug'] ?? ''));
if ($slug === '') { http_response_code(400); exit('Missing slug'); }
$st = $db->prepare('SELECT * FROM categories WHERE slug = ?');
$st->execute([$slug]); $cat = $st->fetch();
if (!$cat) {
  http_response_code(404); ob_start(); require LF_ROOT . '/views/404.php'; $content = ob_get_clean();
  $title = t('not_found'); require LF_ROOT . '/views/layout.php'; exit;
}
$page = max(1, (int)($_GET['page'] ?? 1));
$per = 25; $off = ($page - 1) * $per;
$tagSlug = trim((string)($_GET['tag'] ?? ''));
$tagq    = trim((string)($_GET['tq'] ?? ''));
$where = 't.category_id = ?';
$args  = [(int)$cat['id']];
if ($tagSlug !== '') {
  $where .= ' AND t.id IN (SELECT tt.topic_id FROM topic_tags tt JOIN tags g ON g.id = tt.tag_id WHERE g.slug = ?)';
  $args[] = $tagSlug;
}
$cnt = $db->prepare("SELECT COUNT(*) FROM topics t WHERE $where");
$cnt->execute($args);
$total = (int)$cnt->fetchColumn();
$tst = $db->prepare(
  "SELECT t.*, u.username, u.avatar_color, u.is_verified,
          (SELECT COUNT(*) FROM posts p WHERE p.topic_id = t.id AND p.is_deleted = 0) AS post_count
   FROM topics t JOIN users u ON u.id = t.user_id
   WHERE $where ORDER BY t.is_pinned DESC, t.updated_at DESC LIMIT ? OFFSET ?"
);
$tst->execute(array_merge($args, [$per, $off]));
$topics = $tst->fetchAll();
$tagsByTopic = tags_for_topics($db, array_map(fn($x) => (int)$x['id'], $topics));
$ctg = $db->prepare('SELECT g.name, g.slug FROM category_tags ct JOIN tags g ON g.id = ct.tag_id WHERE ct.category_id = ? ORDER BY g.name');
$ctg->execute([(int)$cat['id']]); $allCatTags = $ctg->fetchAll();
$tagHits = $tagq !== '' ? tag_search($db, $tagq) : [];
$title = cat_name($cat, $_SESSION['ui_lang']);
ob_start(); require LF_ROOT . '/views/category.php'; $content = ob_get_clean();
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/topic.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$id = (int)($_GET['id'] ?? 0);
if ($id <= 0) { http_response_code(400); exit('Missing id'); }
$tst = $db->prepare('SELECT t.*, u.username, u.is_verified, c.slug AS cat_slug
                     FROM topics t JOIN users u ON u.id = t.user_id JOIN categories c ON c.id = t.category_id WHERE t.id = ?');
$tst->execute([$id]); $topic = $tst->fetch();
if (!$topic) {
  http_response_code(404); ob_start(); require LF_ROOT . '/views/404.php'; $content = ob_get_clean();
  $title = t('not_found'); require LF_ROOT . '/views/layout.php'; exit;
}

$skey = 'viewed_' . $id;
if (empty($_SESSION[$skey])) {
  $db->prepare('UPDATE topics SET views = views + 1 WHERE id = ?')->execute([$id]);
  $_SESSION[$skey] = true;
  $topic['views'] = (int)$topic['views'] + 1;
}
$catSt = $db->prepare('SELECT * FROM categories WHERE id = ?'); $catSt->execute([(int)$topic['category_id']]);
$cat = $catSt->fetch();
$topic['cat_name'] = cat_name($cat, $_SESSION['ui_lang']);

$u = auth_user();
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $u) {
  csrf_verify();
  $action = $_POST['action'] ?? '';
  if ($action === 'toggle_watch') {
    $w = $db->prepare('SELECT 1 FROM topic_watches WHERE user_id = ? AND topic_id = ?');
    $w->execute([(int)$u['id'], $id]);
    if ($w->fetchColumn()) {
      $db->prepare('DELETE FROM topic_watches WHERE user_id = ? AND topic_id = ?')->execute([(int)$u['id'], $id]);
      flash_set('ok', t('topic_watch_off'));
    } else {
      $db->prepare('INSERT INTO topic_watches(user_id, topic_id, created_at) VALUES(?, ?, ?)')->execute([(int)$u['id'], $id, time()]);
      flash_set('ok', t('topic_watch_on'));
    }
  } elseif ($action === 'reply' && empty($topic['is_locked'])) {
    $body = trim((string)($_POST['body'] ?? ''));
    try { $body = append_upload($db, $body, (int)$u['id']); }
    catch (RuntimeException $ex) { flash_set('err', $ex->getMessage()); $body = ''; }
    if ($body !== '') {
      if (rate_limit($db, 'post', client_ip(), $config['rate_limit']['post_per_min'], 60)) {
        $db->prepare('INSERT INTO posts(topic_id, user_id, body, created_at, updated_at) VALUES(?, ?, ?, ?, ?)')
           ->execute([$id, (int)$u['id'], $body, time(), time()]);
        $newPostId = (int)$db->lastInsertId();
        $db->prepare('UPDATE topics SET updated_at = ? WHERE id = ?')->execute([time(), $id]);
        notif_for_mentions($db, $body, $id, $newPostId, (int)$u['id']);
        notif_for_replies($db, $id, $newPostId, (int)$u['id'], $body);
        ai_enqueue($db, $id, $newPostId, (int)$u['id'], (int)$topic['category_id']);
      } else {
        flash_set('err', t('post_too_fast'));
      }
    }
  }
  redirect('/topic.php?id=' . $id);
}

$pst = $db->prepare('SELECT p.*, u.username, u.avatar_color, u.is_verified, r.name AS role_name, r.color_hex AS role_color
                     FROM posts p JOIN users u ON u.id = p.user_id LEFT JOIN roles r ON r.id = u.role_id
                     WHERE p.topic_id = ? ORDER BY p.created_at ASC');
$pst->execute([$id]); $posts = $pst->fetchAll();

$reactions = []; $myReacted = [];
if (!empty($posts)) {
  $pids = array_map(fn($p) => (int)$p['id'], $posts);
  $ph = implode(',', array_fill(0, count($pids), '?'));
  $rs = $db->prepare("SELECT post_id, emoji, COUNT(*) AS c FROM post_reactions WHERE post_id IN ($ph) GROUP BY post_id, emoji");
  $rs->execute($pids);
  foreach ($rs->fetchAll() as $r) { $reactions[(int)$r['post_id']][$r['emoji']] = (int)$r['c']; }
  if ($u) {
    $rs2 = $db->prepare("SELECT post_id, emoji FROM post_reactions WHERE user_id = ? AND post_id IN ($ph)");
    $rs2->execute(array_merge([(int)$u['id']], $pids));
    foreach ($rs2->fetchAll() as $r) { $myReacted[(int)$r['post_id']][] = $r['emoji']; }
  }
}

$watching = false;
if ($u) {
  $w = $db->prepare('SELECT 1 FROM topic_watches WHERE user_id = ? AND topic_id = ?');
  $w->execute([(int)$u['id'], $id]); $watching = (bool)$w->fetchColumn();
}
$tgs = $db->prepare('SELECT g.name, g.slug FROM topic_tags tt JOIN tags g ON g.id = tt.tag_id WHERE tt.topic_id = ? ORDER BY g.name');
$tgs->execute([$id]); $topicTags = $tgs->fetchAll();
$title = $topic['title'];
ob_start(); require LF_ROOT . '/views/topic.php'; $content = ob_get_clean();
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/new-topic.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$u = auth_require();
$catId = (int)($_GET['cat'] ?? 0);
$st = $db->prepare('SELECT * FROM categories WHERE id = ?');
$st->execute([$catId]); $cat = $st->fetch();
if (!$cat) {
  http_response_code(404); ob_start(); require LF_ROOT . '/views/404.php'; $content = ob_get_clean();
  $title = t('not_found'); require LF_ROOT . '/views/layout.php'; exit;
}
$error = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
  csrf_verify();
  $title_in = trim((string)($_POST['title'] ?? ''));
  $body     = trim((string)($_POST['body'] ?? ''));
  if (strlen($title_in) < 3 || $body === '') $error = t('title_body_required');
  elseif (!rate_limit($db, 'post', client_ip(), $config['rate_limit']['post_per_min'], 60)) $error = t('rate_wait');
  else {
    try { $body = append_upload($db, $body, (int)$u['id']); }
    catch (RuntimeException $ex) { $error = $ex->getMessage(); }
    if ($error === '') {
      $slug = preg_replace('/[^a-z0-9]+/', '-', strtolower($title_in));
      $db->prepare('INSERT INTO topics(category_id, user_id, title, slug, created_at, updated_at) VALUES(?, ?, ?, ?, ?, ?)')
         ->execute([$catId, (int)$u['id'], $title_in, $slug, time(), time()]);
      $tid = (int)$db->lastInsertId();
      $db->prepare('INSERT INTO posts(topic_id, user_id, body, created_at, updated_at) VALUES(?, ?, ?, ?, ?)')
         ->execute([$tid, (int)$u['id'], $body, time(), time()]);
      $newPostId = (int)$db->lastInsertId();
      tags_save($db, $tid, $catId, array_map('intval', (array)($_POST['tags'] ?? [])));
      ai_enqueue($db, $tid, $newPostId, (int)$u['id'], $catId);
      redirect('/topic.php?id=' . $tid);
    }
  }
}
$tgq = $db->prepare('SELECT g.id, g.name FROM category_tags ct JOIN tags g ON g.id = ct.tag_id WHERE ct.category_id = ? ORDER BY g.name');
$tgq->execute([$catId]); $allowedTags = $tgq->fetchAll();
$title = t('new_topic');
ob_start(); require LF_ROOT . '/views/new-topic.php'; $content = ob_get_clean();
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/search.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$q        = trim((string)($_GET['q'] ?? ''));
$catId    = isset($_GET['cat']) && $_GET['cat'] !== '' ? (int)$_GET['cat'] : null;
$author   = trim((string)($_GET['author'] ?? ''));
$authorId = null;
if ($author !== '') {
  $a = $db->prepare('SELECT id FROM users WHERE username = ?'); $a->execute([$author]);
  $authorId = $a->fetchColumn() ?: null;
}
$page   = max(1, (int)($_GET['page'] ?? 1));
$result = $q !== '' ? search_posts($db, $q, $catId, $authorId ? (int)$authorId : null, $page, 20) : ['rows' => [], 'total' => 0];
$cats   = $db->query('SELECT * FROM categories ORDER BY position, id')->fetchAll();
$title  = t('search');
ob_start(); require LF_ROOT . '/views/search.php'; $content = ob_get_clean();
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/notifications.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$u = auth_require();
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
  csrf_verify();
  if (($_POST['action'] ?? '') === 'mark_all') notif_mark_all_read($db, (int)$u['id']);
  redirect('/notifications.php');
}
$items = notif_list($db, (int)$u['id'], 50);
$title = t('notifications');
ob_start(); require LF_ROOT . '/views/notifications.php'; $content = ob_get_clean();
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/settings.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$u = auth_require();
$row = $db->prepare('SELECT * FROM users WHERE id = ?'); $row->execute([(int)$u['id']]); $user = $row->fetch();
$error = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
  csrf_verify();
  $action = $_POST['action'] ?? 'profile';
  if ($action === 'profile') {
    $bio    = mb_substr(trim((string)($_POST['bio'] ?? '')), 0, 500);
    $theme  = in_array($_POST['theme'] ?? '', $config['themes'], true) ? $_POST['theme'] : 'dark';
    $accent = in_array($_POST['accent'] ?? '', $config['accents'], true) ? $_POST['accent'] : 'indigo';
    $avatarColor = preg_match('/^#[0-9a-fA-F]{6}$/', $_POST['avatar_color'] ?? '') ? $_POST['avatar_color'] : '#6366f1';
    $nm = isset($_POST['notify_mentions'])  ? 1 : 0;
    $nr = isset($_POST['notify_replies'])   ? 1 : 0;
    $nx = isset($_POST['notify_reactions']) ? 1 : 0;
    $nd = isset($_POST['notify_digest'])    ? 1 : 0;
    $db->prepare('UPDATE users SET bio = ?, theme = ?, accent = ?, avatar_color = ?, notify_mentions = ?, notify_replies = ?, notify_reactions = ?, notify_digest = ? WHERE id = ?')
       ->execute([$bio, $theme, $accent, $avatarColor, $nm, $nr, $nx, $nd, (int)$u['id']]);
    $_SESSION['user'] = array_merge($_SESSION['user'], [
      'theme' => $theme, 'accent' => $accent, 'bio' => $bio, 'avatar_color' => $avatarColor,
      'notify_mentions' => $nm, 'notify_replies' => $nr, 'notify_reactions' => $nx, 'notify_digest' => $nd,
    ]);
    audit($db, $u, 'user.settings_update');
    flash_set('ok', t('settings_saved'));
    redirect('/settings.php');
  } elseif ($action === 'password') {
    $cur  = (string)($_POST['current_password'] ?? '');
    $new  = (string)($_POST['new_password'] ?? '');
    $conf = (string)($_POST['confirm_password'] ?? '');
    if (!password_verify_safe($cur, $user['password_hash'])) $error = t('password_wrong');
    elseif (strlen($new) < 10) $error = t('weak_password');
    elseif ($new !== $conf)    $error = t('password_mismatch');
    else {
      $db->prepare('UPDATE users SET password_hash = ? WHERE id = ?')->execute([password_hash_safe($new), (int)$u['id']]);
      audit($db, $u, 'user.password_change');
      flash_set('ok', t('password_changed'));
      redirect('/settings.php');
    }
  }
  $row = $db->prepare('SELECT * FROM users WHERE id = ?'); $row->execute([(int)$u['id']]); $user = $row->fetch();
}
$title = t('settings');
ob_start(); require LF_ROOT . '/views/settings.php'; $content = ob_get_clean();
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/user.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$uname = trim((string)($_GET['u'] ?? ''));
if ($uname === '') { http_response_code(400); exit('Missing username'); }
$st = $db->prepare('SELECT * FROM users WHERE username = ?');
$st->execute([$uname]); $profile = $st->fetch();
if (!$profile) {
  http_response_code(404); ob_start(); require LF_ROOT . '/views/404.php'; $content = ob_get_clean();
  $title = t('not_found'); require LF_ROOT . '/views/layout.php'; exit;
}
$tst = $db->prepare('SELECT t.*, c.slug AS cat_slug, c.name_en, c.name_tr, c.name_fr, c.name_de, c.name_es, c.name_ar
                     FROM topics t JOIN categories c ON c.id = t.category_id WHERE t.user_id = ? ORDER BY t.updated_at DESC LIMIT 20');
$tst->execute([(int)$profile['id']]); $topics = $tst->fetchAll();
$lc = $_SESSION['ui_lang'];
foreach ($topics as &$tp) { $tp['cat_name'] = cat_name($tp, $lc); }
unset($tp);
$pst = $db->prepare('SELECT p.*, t.title AS topic_title FROM posts p JOIN topics t ON t.id = p.topic_id
                     WHERE p.user_id = ? AND p.is_deleted = 0 ORDER BY p.created_at DESC LIMIT 20');
$pst->execute([(int)$profile['id']]); $posts = $pst->fetchAll();
$title = '@' . $profile['username'];
ob_start(); require LF_ROOT . '/views/user.php'; $content = ob_get_clean();
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/stats.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$stats = forum_stats($db);
$topUsers = $db->query('SELECT u.username, u.avatar_color, COUNT(p.id) AS cnt FROM users u JOIN posts p ON p.user_id = u.id WHERE p.is_deleted = 0 GROUP BY u.id ORDER BY cnt DESC LIMIT 10')->fetchAll();
$title = t('stats');
ob_start(); require LF_ROOT . '/views/stats.php'; $content = ob_get_clean();
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/activity.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$topics = recent_topics($db, 15);
$posts  = recent_posts($db, 15);
$title  = t('activity');
ob_start(); require LF_ROOT . '/views/activity.php'; $content = ob_get_clean();
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/react.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
if ($_SERVER['REQUEST_METHOD'] !== 'POST') { http_response_code(405); exit; }
$u = auth_require();
csrf_verify();
$postId = (int)($_POST['post_id'] ?? 0);
$emoji  = (string)($_POST['emoji'] ?? '');
$back   = (string)($_POST['back'] ?? '/');
if ($postId > 0 && in_array($emoji, ['👍', '❤️', '🔥', '😂', '😮'], true)
    && rate_limit($db, 'react', client_ip(), $config['rate_limit']['react_per_min'], 60)) {
  $st = $db->prepare('SELECT 1 FROM post_reactions WHERE post_id = ? AND user_id = ? AND emoji = ?');
  $st->execute([$postId, (int)$u['id'], $emoji]);
  if ($st->fetchColumn()) {
    $db->prepare('DELETE FROM post_reactions WHERE post_id = ? AND user_id = ? AND emoji = ?')->execute([$postId, (int)$u['id'], $emoji]);
  } else {
    $db->prepare('INSERT INTO post_reactions(post_id, user_id, emoji, created_at) VALUES(?, ?, ?, ?)')->execute([$postId, (int)$u['id'], $emoji, time()]);
    notif_for_reaction($db, $postId, (int)$u['id'], $emoji);
  }
}
redirect(safe_next($back));
PHP

  cat > "$APP_DIR/public/mod.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
if ($_SERVER['REQUEST_METHOD'] !== 'POST') { http_response_code(405); exit; }
$u = auth_mod();
csrf_verify();
$action  = $_POST['action'] ?? '';
$topicId = (int)($_POST['topic_id'] ?? 0);
$postId  = (int)($_POST['post_id'] ?? 0);
$userId  = (int)($_POST['user_id'] ?? 0);
$state   = (int)($_POST['state'] ?? 0);

if ($action === 'pin' && $topicId > 0) {
  $db->prepare('UPDATE topics SET is_pinned = ? WHERE id = ?')->execute([$state, $topicId]);
  audit($db, $u, $state ? 'topic.pin' : 'topic.unpin', 'topic', $topicId);
  flash_set('ok', t('saved'));
  redirect('/topic.php?id=' . $topicId);
}
if ($action === 'lock' && $topicId > 0) {
  $db->prepare('UPDATE topics SET is_locked = ? WHERE id = ?')->execute([$state, $topicId]);
  audit($db, $u, $state ? 'topic.lock' : 'topic.unlock', 'topic', $topicId);
  flash_set('ok', t('saved'));
  redirect('/topic.php?id=' . $topicId);
}
if ($action === 'delete_post' && $postId > 0) {
  $st = $db->prepare('SELECT topic_id FROM posts WHERE id = ?'); $st->execute([$postId]);
  $p = $st->fetch();
  if ($p) {
    $db->prepare('UPDATE posts SET is_deleted = 1 WHERE id = ?')->execute([$postId]);
    audit($db, $u, 'post.delete', 'post', $postId);
  }
  flash_set('ok', t('saved'));
  redirect('/topic.php?id=' . ($p ? (int)$p['topic_id'] : $topicId));
}
if ($action === 'delete_topic' && $topicId > 0) {
  if (!is_admin($u)) { http_response_code(403); exit(t('mod_only')); }
  $st = $db->prepare('SELECT c.slug FROM topics t JOIN categories c ON c.id = t.category_id WHERE t.id = ?');
  $st->execute([$topicId]); $slug = $st->fetchColumn();
  $db->prepare('DELETE FROM topics WHERE id = ?')->execute([$topicId]);
  audit($db, $u, 'topic.delete', 'topic', $topicId);
  flash_set('ok', t('saved'));
  redirect($slug ? '/category.php?slug=' . urlencode((string)$slug) : '/');
}
if ($action === 'ban_user' && $userId > 0) {
  if (!is_admin($u)) { http_response_code(403); exit(t('mod_only')); }
  $db->prepare('UPDATE users SET banned = ? WHERE id = ?')->execute([$state, $userId]);
  audit($db, $u, $state ? 'user.ban' : 'user.unban', 'user', $userId);
  flash_set('ok', t('saved'));
  $st = $db->prepare('SELECT username FROM users WHERE id = ?'); $st->execute([$userId]);
  redirect('/user.php?u=' . urlencode((string)$st->fetchColumn()));
}
redirect('/');
PHP

  cat > "$APP_DIR/public/admin.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$u = auth_admin();
const ADMIN_TABS = ['general', 'ai', 'turnstile', 'users', 'categories', 'audit'];

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
  csrf_verify();
  $action = (string)($_POST['action'] ?? '');
  $tab = in_array($_POST['tab'] ?? '', ADMIN_TABS, true) ? $_POST['tab'] : 'general';

  if (admin_extra_action($db, $u, $config, $action)) redirect('/admin.php?tab=' . $tab);

  if ($action === 'save_settings') {
    $name    = trim((string)($_POST['app_name'] ?? ''));
    $tagline = trim((string)($_POST['app_tagline'] ?? ''));
    if ($name !== '') settings_set($db, 'app_name', mb_substr($name, 0, 60));
    settings_set($db, 'app_tagline', mb_substr($tagline, 0, 160));
    audit($db, $u, 'site.settings');
    flash_set('ok', t('settings_saved'));
  } elseif ($action === 'bulk_role') {
    $ids  = array_filter(array_map('intval', explode(',', (string)($_POST['ids'] ?? ''))));
    $role = in_array($_POST['role'] ?? '', ['member', 'moderator', 'admin'], true) ? $_POST['role'] : 'member';
    foreach ($ids as $id) {
      $db->prepare('UPDATE users SET role = ? WHERE id = ?')->execute([$role, $id]);
      audit($db, $u, 'user.role_set', 'user', $id, ['role' => $role]);
    }
    flash_set('ok', t('saved'));
  } elseif ($action === 'add_category') {
    $slug   = preg_replace('/[^a-z0-9\-]/', '', strtolower((string)($_POST['slug'] ?? '')));
    $nameTr = trim((string)($_POST['name_tr'] ?? ''));
    $nameEn = trim((string)($_POST['name_en'] ?? ''));
    if ($slug !== '' && $nameTr !== '' && $nameEn !== '') {
      try {
        $db->prepare('INSERT INTO categories(slug, name_tr, name_en, description_tr, description_en, icon, position) VALUES(?, ?, ?, ?, ?, ?, ?)')
           ->execute([$slug, $nameTr, $nameEn,
                      (string)($_POST['description_tr'] ?? ''), (string)($_POST['description_en'] ?? ''),
                      mb_substr((string)($_POST['icon'] ?? '💬'), 0, 4), (int)($_POST['position'] ?? 0)]);
        audit($db, $u, 'category.create', 'category', (int)$db->lastInsertId());
        flash_set('ok', t('saved'));
      } catch (PDOException) {
        flash_set('err', t('already_exists'));
      }
    }
  } elseif ($action === 'edit_category') {
    $id   = (int)($_POST['id'] ?? 0);
    $slug = preg_replace('/[^a-z0-9\-]/', '', strtolower((string)($_POST['slug'] ?? '')));
    if ($id > 0 && $slug !== '') {
      $db->prepare('UPDATE categories SET slug = ?, name_tr = ?, name_en = ?, name_fr = ?, name_de = ?, name_es = ?, name_ar = ?,
                    description_tr = ?, description_en = ?, icon = ?, position = ? WHERE id = ?')
         ->execute([$slug,
                    (string)($_POST['name_tr'] ?? ''), (string)($_POST['name_en'] ?? ''),
                    (string)($_POST['name_fr'] ?? ''), (string)($_POST['name_de'] ?? ''),
                    (string)($_POST['name_es'] ?? ''), (string)($_POST['name_ar'] ?? ''),
                    (string)($_POST['description_tr'] ?? ''), (string)($_POST['description_en'] ?? ''),
                    mb_substr((string)($_POST['icon'] ?? '💬'), 0, 4), (int)($_POST['position'] ?? 0), $id]);
      audit($db, $u, 'category.update', 'category', $id);
      flash_set('ok', t('saved'));
    }
  } elseif ($action === 'delete_category') {
    $id = (int)($_POST['id'] ?? 0);
    if ($id > 0) {
      $db->prepare('DELETE FROM categories WHERE id = ?')->execute([$id]);
      audit($db, $u, 'category.delete', 'category', $id);
      flash_set('ok', t('saved'));
    }
  }
  redirect('/admin.php?tab=' . $tab);
}

$tab = in_array($_GET['tab'] ?? '', ADMIN_TABS, true) ? $_GET['tab'] : 'general';
$users = []; $roles = []; $cats = []; $catTags = []; $audit = []; $editCat = null;
$providers = []; $profiles = []; $catsAll = []; $editProfile = null; $aiEnabled = '0';
$adapters = ai_adapters();

if ($tab === 'users') {
  $users = $db->query('SELECT id, username, email, role, banned, is_verified FROM users ORDER BY id DESC LIMIT 200')->fetchAll();
  $roles = $db->query('SELECT * FROM roles ORDER BY power_level DESC, id')->fetchAll();
}
if ($tab === 'categories') {
  $cats = $db->query('SELECT * FROM categories ORDER BY position, id')->fetchAll();
  foreach ($db->query('SELECT ct.category_id, g.name FROM category_tags ct JOIN tags g ON g.id = ct.tag_id ORDER BY g.name')->fetchAll() as $r) {
    $catTags[(int)$r['category_id']][] = $r['name'];
  }
  if (!empty($_GET['edit_cat'])) {
    $st = $db->prepare('SELECT * FROM categories WHERE id = ?');
    $st->execute([(int)$_GET['edit_cat']]); $editCat = $st->fetch() ?: null;
  }
}
if ($tab === 'ai') {
  $aiEnabled = settings_get($db, 'ai_enabled', '0');
  $providers = $db->query('SELECT * FROM ai_providers ORDER BY builtin DESC, id')->fetchAll();
  $catsAll   = $db->query('SELECT id, name_en, name_tr FROM categories ORDER BY position, id')->fetchAll();
  $profiles  = $db->query('SELECT p.*, pr.name AS provider_name, pr.default_model, c.name_en AS cat_name
                           FROM ai_profiles p
                           JOIN ai_providers pr ON pr.id = p.provider_id
                           LEFT JOIN categories c ON c.id = p.category_id
                           ORDER BY p.id')->fetchAll();
  if (!empty($_GET['edit_profile'])) {
    $st = $db->prepare('SELECT * FROM ai_profiles WHERE id = ?');
    $st->execute([(int)$_GET['edit_profile']]); $editProfile = $st->fetch() ?: null;
  }
}
if ($tab === 'audit') {
  $audit = $db->query('SELECT a.*, u.username AS actor FROM audit_log a LEFT JOIN users u ON u.id = a.actor_id ORDER BY a.ts DESC LIMIT 100')->fetchAll();
}
$appName    = $GLOBALS['__app_name'];
$appTagline = $GLOBALS['__app_tagline'];
$title = t('admin_panel');
ob_start(); require LF_ROOT . '/views/admin.php'; $content = ob_get_clean();
require LF_ROOT . '/views/layout.php';
PHP

  cat > "$APP_DIR/public/oauth/erendev/callback.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__, 3) . '/app/bootstrap.php';
if (($config['default_lang'] ?? '') !== 'tr' || ($_SESSION['ui_lang'] ?? '') !== 'tr') { http_response_code(404); exit('Not found.'); }
$state = (string)($_GET['state'] ?? ''); $code = (string)($_GET['code'] ?? '');
if ($state === '' || !hash_equals($_SESSION['erendev_state'] ?? '', $state)) { http_response_code(400); exit('Invalid state'); }
unset($_SESSION['erendev_state']);
if ($code === '') { http_response_code(400); exit('Missing code'); }
$ch = curl_init($config['erendev']['token_url']);
curl_setopt_array($ch, [
  CURLOPT_POST => true, CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 15,
  CURLOPT_SSL_VERIFYPEER => true, CURLOPT_SSL_VERIFYHOST => 2,
  CURLOPT_POSTFIELDS => http_build_query([
    'grant_type' => 'authorization_code', 'code' => $code,
    'redirect_uri' => $config['erendev']['redirect_uri'],
    'client_id' => $config['erendev']['client_id'],
    'client_secret' => $config['erendev']['client_secret'],
  ]),
]);
$resp = curl_exec($ch);
if (curl_errno($ch)) { http_response_code(502); exit('Token exchange failed'); }
curl_close($ch);
$tok = json_decode((string)$resp, true);
if (empty($tok['access_token'])) { http_response_code(502); exit('No token'); }
$ch2 = curl_init($config['erendev']['userinfo_url']);
curl_setopt_array($ch2, [
  CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 10,
  CURLOPT_HTTPHEADER => ['Authorization: Bearer ' . $tok['access_token']],
  CURLOPT_SSL_VERIFYPEER => true,
]);
$u2 = json_decode((string)curl_exec($ch2), true);
curl_close($ch2);
if (empty($u2['sub']) || empty($u2['email'])) { http_response_code(502); exit('Bad userinfo'); }
if (!filter_var($u2['email_verified'] ?? false, FILTER_VALIDATE_BOOLEAN)) { http_response_code(403); exit('Email not verified at provider.'); }
$sub   = (string)$u2['sub'];
$email = (string)$u2['email'];
$username = (string)($u2['preferred_username'] ?? '');
if (!preg_match('/^[A-Za-z0-9_\-]{3,32}$/', $username)) $username = 'ed_' . substr(hash('sha256', $sub), 0, 10);
$st = $db->prepare('SELECT * FROM users WHERE erendev_sub = ?');
$st->execute([$sub]); $user = $st->fetch();
if (!$user) {
  $chk = $db->prepare('SELECT 1 FROM users WHERE email = ?'); $chk->execute([$email]);
  if ($chk->fetchColumn()) { http_response_code(409); exit(t('email_taken')); }
  $db->prepare('INSERT INTO users(username, email, password_hash, erendev_sub, created_at, last_seen_at) VALUES(?, ?, ?, ?, ?, ?)')
     ->execute([$username, $email, password_hash_safe(bin2hex(random_bytes(24))), $sub, time(), time()]);
  $st = $db->prepare('SELECT * FROM users WHERE id = ?'); $st->execute([$db->lastInsertId()]); $user = $st->fetch();
}
if ((int)$user['banned'] === 1) { http_response_code(403); exit(t('banned_msg')); }
auth_login($user);
redirect('/');
PHP

  cat > "$APP_DIR/public/media.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
$f = (string)($_GET['f'] ?? '');
if (!preg_match('/^[a-f0-9]{32}\.(jpg|png|gif|webp)$/', $f)) { http_response_code(404); exit; }
$st = $db->prepare('SELECT mime FROM uploads WHERE stored_name = ?');
$st->execute([$f]);
$mime = $st->fetchColumn();
$path = upload_dir() . '/' . $f;
if (!$mime || !is_file($path)) { http_response_code(404); exit; }
header('Content-Type: ' . $mime);
header('Content-Length: ' . filesize($path));
header('X-Content-Type-Options: nosniff');
header('Cache-Control: public, max-age=31536000, immutable');
readfile($path);
PHP

  cat > "$APP_DIR/public/404.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__) . '/app/bootstrap.php';
http_response_code(404);
ob_start(); require LF_ROOT . '/views/404.php'; $content = ob_get_clean();
$title = t('not_found');
require LF_ROOT . '/views/layout.php';
PHP

  chown -R root:root "$APP_DIR/public"
  find "$APP_DIR/public" -type d -exec chmod 0755 {} \;
  find "$APP_DIR/public" -type f -exec chmod 0644 {} \;
  ok "public/"
}

write_env() {
  cat > "$APP_DIR/config/config.php" <<PHP
<?php
return [
    'app_name'         => 'LiteForum',
    'default_lang'     => '$LANG_CODE',
    'available_langs'  => ['tr', 'en', 'fr', 'de', 'es', 'ar'],
    'app_key'          => '$APP_KEY',
    'db_path'          => '$DATA_DIR/liteforum.db',
    'base_url'         => '$PUBLIC_BASE',
    'session_name'     => 'LF_SESSION',
    'session_lifetime' => 7200,
    'erendev' => [
        'client_id'     => '$OAUTH_CLIENT_ID',
        'client_secret' => '$OAUTH_CLIENT_SECRET',
        'authorize_url' => 'https://oauth2.erendev.xyz/oauth/authorize',
        'token_url'     => 'https://oauth2.erendev.xyz/oauth/token',
        'userinfo_url'  => 'https://oauth2.erendev.xyz/oauth/userinfo',
        'redirect_uri'  => '$PUBLIC_BASE/oauth/erendev/callback.php',
        'scope'         => 'profile email',
        'button_svg'    => 'https://oauth2.erendev.xyz/erendev-login-button.svg',
    ],
    'rate_limit' => ['login_per_10min' => 10, 'post_per_min' => 6, 'register_per_hr' => 5, 'react_per_min' => 30, 'reset_per_hr' => 3],
    'themes'     => ['dark', 'light', 'high-contrast'],
    'accents'    => ['indigo', 'emerald', 'rose', 'amber', 'sky'],
    'admin_email' => '$ADMIN_EMAIL',
];
PHP
  chown root:"$SVC_USER" "$APP_DIR/config/config.php"
  chmod 0640 "$APP_DIR/config/config.php"
  ok "config.php ($PUBLIC_BASE)"
}

write_phpfpm() {
  local pool="/etc/php/${PHP_VER#php}/fpm/pool.d/liteforum.conf"
  install -d -o root -g root -m 0755 "$(dirname "$pool")"
  cat > "$pool" <<FPM
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
php_admin_value[open_basedir] = $APP_DIR:$DATA_DIR:/tmp:/var/log/liteforum
php_admin_value[upload_max_filesize] = 6M
php_admin_value[post_max_size] = 8M
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec,show_source,phpinfo
php_admin_value[upload_tmp_dir] = $DATA_DIR/tmp
php_admin_value[session.save_path] = $DATA_DIR/sessions
php_admin_flag[session.cookie_httponly] = on
php_admin_flag[session.use_strict_mode] = on
php_admin_flag[session.use_only_cookies] = on
php_admin_value[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 64
php_admin_value[opcache.validate_timestamps] = 1
php_admin_value[opcache.revalidate_freq] = 0
FPM
  chmod 0644 "$pool"
  ok "PHP-FPM pool"
}

setup_ufw() {
  [[ $NO_FIREWALL -eq 1 ]] && { warn "UFW skipped"; return; }
  local ssh_port
  ssh_port="$(ss -tlnp 2>/dev/null | awk '/sshd/{print $4}' | grep -oE '[0-9]+$' | head -1 || true)"
  [[ -n "$ssh_port" ]] || ssh_port=22
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${ssh_port}/tcp" comment 'SSH'
  if [[ $CF_NAMED -eq 0 && $CLOUDFLARED -eq 0 ]]; then
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    [[ "$HTTP_PORT" != "80" ]] && ufw allow "${HTTP_PORT}/tcp" comment 'LiteForum HTTP'
  fi
  ufw --force enable
  ok "UFW enabled (SSH port $ssh_port)"
}

setup_fail2ban() {
  install -d -o root -g root -m 0755 /etc/fail2ban/jail.d
  cat > /etc/fail2ban/jail.d/liteforum.local <<F2B
[sshd]
enabled = true
maxretry = 4
findtime = 10m
bantime = 1h

[nginx-http-auth]
enabled = true
port = http,https
logpath = $LOG_DIR/error.log
maxretry = 5
findtime = 10m
bantime = 1h

[nginx-limit-req]
enabled = true
port = http,https
logpath = $LOG_DIR/error.log
maxretry = 10
findtime = 10m
bantime = 1h
F2B
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  ok "Fail2ban"
}

setup_sysctl() {
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
  rm -f /etc/nginx/sites-enabled/default
  cat > /etc/nginx/sites-available/liteforum.http <<HTTP
server {
  listen 80; listen [::]:80;
  server_name $DOMAIN;
  root $APP_DIR/public;
  location /.well-known/acme-challenge/ { allow all; }
  location / { return 200 'ok'; }
}
HTTP
  ln -sf /etc/nginx/sites-available/liteforum.http /etc/nginx/sites-enabled/liteforum.http
  rm -f /etc/nginx/sites-enabled/liteforum
  nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
  if certbot certonly --webroot -w "$APP_DIR/public" -d "$DOMAIN" -m "$EMAIL" \
       --agree-tos --non-interactive >>"$INSTALL_LOG" 2>&1; then
    ok "TLS certificate issued"
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  else
    warn "Certbot failed, continuing with HTTP (check DNS for $DOMAIN)"
    SKIP_TLS=1
  fi
  rm -f /etc/nginx/sites-enabled/liteforum.http
}

write_nginx() {
  local SOCK="/run/php/${PHP_VER}-fpm-liteforum.sock"
  local CSP="default-src 'self'; img-src 'self' https://oauth2.erendev.xyz data:; style-src 'self' 'unsafe-inline'; script-src 'self' https://challenges.cloudflare.com; connect-src 'self' https://challenges.cloudflare.com; frame-src https://challenges.cloudflare.com; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self' https://oauth2.erendev.xyz"

  HAS_TLS=0
  if [[ $SKIP_TLS -eq 0 && -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then HAS_TLS=1; fi

  cat > /etc/nginx/conf.d/liteforum-zones.conf <<'ZONES'
limit_req_zone $binary_remote_addr zone=lf_login:10m rate=10r/m;
ZONES

  cat > /etc/nginx/liteforum-fcgi.conf <<FCGI
try_files \$uri =404;
fastcgi_pass unix:$SOCK;
include fastcgi_params;
fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
fastcgi_param HTTP_PROXY "";
fastcgi_read_timeout 30s;
FCGI

  cat > /etc/nginx/liteforum-common.conf <<NGINX
add_header Content-Security-Policy "$CSP" always;
add_header X-Frame-Options "DENY" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

root $APP_DIR/public;
index index.php;
server_tokens off;
charset utf-8;
client_max_body_size 10m;

location = /favicon.ico { access_log off; return 204; }
location = /login.php { limit_req zone=lf_login burst=5 nodelay; include /etc/nginx/liteforum-fcgi.conf; }
location ~ \.php\$ { include /etc/nginx/liteforum-fcgi.conf; }
location / { try_files \$uri \$uri/ /index.php?\$query_string; }
location ~ /\.(?!well-known) { deny all; }
location ~* \.(env|log|sqlite|db|sql|bak|ini|conf|md|git)\$ { deny all; }
location ~ /(config|app|lang|views|storage)/ { deny all; }
NGINX

  if [[ $HAS_TLS -eq 1 ]]; then
    cat > /etc/nginx/sites-available/liteforum <<NGINX
server {
  listen 80; listen [::]:80;
  server_name $DOMAIN;
  location /.well-known/acme-challenge/ { allow all; }
  location / { return 301 https://\$host\$request_uri; }
}
server {
  listen 443 ssl http2; listen [::]:443 ssl http2;
  server_name $DOMAIN;
  ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_session_cache shared:SSL:10m;
  ssl_session_timeout 1d;
  add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
  include /etc/nginx/liteforum-common.conf;
  access_log $LOG_DIR/access.log;
  error_log $LOG_DIR/error.log warn;
}
NGINX
  else
    local listen_bind="" ipv6=""
    if [[ $CF_NAMED -eq 1 || $CLOUDFLARED -eq 1 ]]; then
      listen_bind="127.0.0.1:"
    else
      ipv6="  listen [::]:${HTTP_PORT} default_server;"
    fi
    cat > /etc/nginx/sites-available/liteforum <<NGINX
server {
  listen ${listen_bind}${HTTP_PORT} default_server;
${ipv6}
  server_name $DOMAIN;
  include /etc/nginx/liteforum-common.conf;
  access_log $LOG_DIR/access.log;
  error_log $LOG_DIR/error.log warn;
}
NGINX
  fi

  ln -sf /etc/nginx/sites-available/liteforum /etc/nginx/sites-enabled/liteforum
  rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/liteforum.http
  ok "Nginx config ($([[ $HAS_TLS -eq 1 ]] && echo https || echo http), port $HTTP_PORT)"
}

start_services() {
  nginx -t || die "Nginx config invalid"
  systemctl enable "$PHP_VER-fpm" nginx >/dev/null 2>&1 || true
  systemctl restart "$PHP_VER-fpm"
  systemctl restart nginx
  ok "Services up"
}

install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then ok "cloudflared already installed"; return; fi
  local arch
  case "$(dpkg --print-architecture)" in
    amd64) arch=amd64;; arm64) arch=arm64;; armhf) arch=arm;;
    *) die "Unsupported architecture for cloudflared";;
  esac
  curl -fsSL -o /tmp/cloudflared.deb \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb" \
    || die "cloudflared download failed"
  dpkg -i /tmp/cloudflared.deb >/dev/null 2>&1 || apt-get install -f -y -qq
  rm -f /tmp/cloudflared.deb
  command -v cloudflared >/dev/null 2>&1 || die "cloudflared install failed"
  ok "cloudflared installed"
}

wait_tunnel_log() {
  local pattern="$1" i log
  for i in $(seq 1 30); do
    log="$(journalctl -u liteforum-cloudflared --no-pager -n 200 2>/dev/null || true)"
    [[ "$log" == *"$pattern"* ]] && return 0
    sleep 2
  done
  return 1
}

setup_cloudflared() {
  [[ $CLOUDFLARED -eq 1 ]] || return 0
  install_cloudflared
  cat > /etc/systemd/system/liteforum-cloudflared.service <<UNIT
[Unit]
Description=LiteForum Cloudflare quick tunnel
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:$HTTP_PORT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now liteforum-cloudflared >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 30); do
    CF_URL="$(journalctl -u liteforum-cloudflared --no-pager -n 300 2>/dev/null \
      | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
    [[ -n "$CF_URL" ]] && break
    sleep 2
  done
  if [[ -n "$CF_URL" ]]; then ok "Cloudflare quick tunnel: $CF_URL"
  else warn "Tunnel URL not found. Check: journalctl -u liteforum-cloudflared -n 50"; fi
}

setup_cf_named() {
  [[ $CF_NAMED -eq 1 && -n "$CF_TOKEN" ]] || return 0
  install_cloudflared
  install -d -o root -g root -m 0700 /etc/liteforum
  ( umask 077; printf 'TUNNEL_TOKEN=%s\n' "$CF_TOKEN" > /etc/liteforum/cloudflared.env )
  cat > /etc/systemd/system/liteforum-cloudflared.service <<UNIT
[Unit]
Description=LiteForum Cloudflare named tunnel
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/liteforum/cloudflared.env
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now liteforum-cloudflared >/dev/null 2>&1 || true
  if wait_tunnel_log "Registered tunnel connection"; then
    ok "Cloudflare named tunnel connected"
  else
    warn "Tunnel connection not confirmed. Check: journalctl -u liteforum-cloudflared -n 50"
  fi
}

setup_cf_login() {
  [[ $CF_LOGIN -eq 1 ]] || return 0
  install_cloudflared
  local TUNNEL_NAME="liteforum" TUNNEL_ID="" CRED_JSON
  install -d -o root -g root -m 0700 /root/.cloudflared

  if [[ ! -f /root/.cloudflared/cert.pem ]]; then
    log "Cloudflare login: open the link below in your browser and choose the zone for $DOMAIN"
    timeout 600 cloudflared tunnel login 2>&1 | tee -a "$INSTALL_LOG" \
      || die "cloudflared login failed or timed out (600s)"
    [[ -f /root/.cloudflared/cert.pem ]] || die "Login finished but cert.pem was not created"
    ok "Cloudflare login complete"
  else
    ok "Existing Cloudflare login found"
  fi

  TUNNEL_ID="$(cloudflared tunnel list -o json 2>/dev/null | jq -r --arg n "$TUNNEL_NAME" '[.[] | select(.name == $n)][0].id // empty' || true)"
  if [[ -z "$TUNNEL_ID" ]]; then
    cloudflared tunnel create "$TUNNEL_NAME" >>"$INSTALL_LOG" 2>&1 || die "Tunnel create failed"
    TUNNEL_ID="$(cloudflared tunnel list -o json 2>/dev/null | jq -r --arg n "$TUNNEL_NAME" '[.[] | select(.name == $n)][0].id // empty' || true)"
  fi
  [[ -n "$TUNNEL_ID" ]] || die "Could not determine tunnel ID for $TUNNEL_NAME"
  ok "Tunnel $TUNNEL_NAME ($TUNNEL_ID)"

  cloudflared tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$DOMAIN" >>"$INSTALL_LOG" 2>&1 \
    || die "DNS route creation failed for $DOMAIN"
  ok "DNS $DOMAIN → tunnel"

  CRED_JSON="/root/.cloudflared/${TUNNEL_ID}.json"
  [[ -f "$CRED_JSON" ]] || die "Tunnel credentials not found: $CRED_JSON"
  install -d -o root -g root -m 0755 /etc/cloudflared
  install -m 0600 -o root -g root "$CRED_JSON" "/etc/cloudflared/${TUNNEL_ID}.json"
  cat > /etc/cloudflared/config.yml <<YML
tunnel: $TUNNEL_ID
credentials-file: /etc/cloudflared/${TUNNEL_ID}.json
ingress:
  - hostname: $DOMAIN
    service: http://127.0.0.1:$HTTP_PORT
  - service: http_status:404
YML

  cat > /etc/systemd/system/liteforum-cloudflared.service <<UNIT
[Unit]
Description=LiteForum Cloudflare tunnel
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now liteforum-cloudflared >/dev/null 2>&1 || true
  if wait_tunnel_log "Registered tunnel connection"; then
    ok "Cloudflare tunnel connected → https://$DOMAIN"
  else
    warn "Tunnel connection not confirmed. Check: journalctl -u liteforum-cloudflared -n 50"
  fi
}

compute_public_base() {
  if   [[ $CF_NAMED -eq 1 ]];      then PUBLIC_BASE="https://$DOMAIN"
  elif [[ $CLOUDFLARED -eq 1 ]];   then PUBLIC_BASE="${CF_URL:-http://127.0.0.1:$HTTP_PORT}"
  elif [[ $HAS_TLS -eq 1 ]];       then PUBLIC_BASE="https://$DOMAIN"
  elif [[ "$HTTP_PORT" == "80" ]]; then PUBLIC_BASE="http://$DOMAIN"
  else                                  PUBLIC_BASE="http://$DOMAIN:$HTTP_PORT"
  fi
}

setup_backups() {
  local PASS=/etc/liteforum/backup.pass
  install -d -o root -g root -m 0700 /etc/liteforum
  if [[ ! -s "$PASS" ]]; then ( umask 077; openssl rand -base64 48 > "$PASS" ); fi
  chmod 0600 "$PASS"
  cat > /usr/local/sbin/liteforum-backup <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
DB=/var/lib/liteforum/liteforum.db
OUT=/var/lib/liteforum/backups
PASS=/etc/liteforum/backup.pass
STAMP="$(date -u +%F-%H%M)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sqlite3 "$DB" ".backup '$TMP/liteforum.db'"
tar czf - -C "$TMP" liteforum.db \
  | openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:$PASS" -out "$OUT/lf-$STAMP.tar.gz.enc"
chown liteforum:liteforum "$OUT/lf-$STAMP.tar.gz.enc"
find "$OUT" -name 'lf-*.tar.gz.enc' -mtime +14 -delete
SH
  chmod 0700 /usr/local/sbin/liteforum-backup
  cat > /etc/cron.d/liteforum-backup <<'CRON'
SHELL=/bin/bash
45 3 * * * root /usr/local/sbin/liteforum-backup >>/var/log/liteforum/backup.log 2>&1
CRON
  chmod 0644 /etc/cron.d/liteforum-backup
  ok "Encrypted daily backup scheduled (03:45 UTC, 14-day retention)"
}

seed_data() {
  local DB="$DATA_DIR/liteforum.db" HASH
  HASH="$(printf '%s' "$ADMIN_PASS" | php -r 'echo password_hash(stream_get_contents(STDIN), PASSWORD_DEFAULT);')"
  sqlite3 "$DB" <<SQL
INSERT INTO categories(slug, name_tr, name_en, name_fr, name_de, name_es, name_ar, description_tr, description_en, icon, position) VALUES
 ('general','Genel','General','Général','Allgemein','General','عام','Genel tartışmalar','General discussions','💬',10),
 ('announcements','Duyurular','Announcements','Annonces','Ankündigungen','Anuncios','إعلانات','Resmi duyurular','Official announcements','📢',20),
 ('support','Destek','Support','Support','Hilfe','Soporte','دعم','Yardım ve destek','Help and support','🛠️',30);

INSERT INTO users(username, email, password_hash, role, created_at, last_seen_at, is_verified)
VALUES('admin', '$ADMIN_EMAIL', '$HASH', 'admin', strftime('%s','now'), strftime('%s','now'), 1);

INSERT INTO ai_providers(slug, name, adapter, base_url, default_model, enabled, builtin) VALUES
 ('anthropic','Anthropic','anthropic','https://api.anthropic.com','claude-haiku-4-5',1,1),
 ('openai','OpenAI','openai','https://api.openai.com/v1','gpt-4o-mini',1,1),
 ('gemini','Google Gemini','gemini','https://generativelanguage.googleapis.com/v1beta','gemini-2.5-flash',1,1),
 ('groq','Groq','groq','https://api.groq.com/openai/v1','llama-3.3-70b-versatile',1,1),
 ('openrouter','OpenRouter','openrouter','https://openrouter.ai/api/v1','openai/gpt-4o-mini',1,1),
 ('mistral','Mistral','mistral','https://api.mistral.ai/v1','mistral-small-latest',1,1),
 ('together','Together AI','together','https://api.together.xyz/v1','meta-llama/Llama-3.3-70B-Instruct-Turbo',1,1),
 ('deepseek','DeepSeek','deepseek','https://api.deepseek.com','deepseek-chat',1,1),
 ('cohere','Cohere','cohere','https://api.cohere.com','command-a-03-2025',1,1),
 ('ollama','Ollama (local)','ollama','http://127.0.0.1:11434','llama3.2',0,1),
 ('custom','Custom OpenAI-compatible','openai_compat','','',0,1);

INSERT INTO users(username, email, password_hash, role, created_at, last_seen_at, is_verified)
VALUES('assistant_$BOT_SUFFIX', 'ai+$BOT_SUFFIX@liteforum.invalid', '!', 'member', strftime('%s','now'), strftime('%s','now'), 1);

INSERT INTO ai_profiles(name, provider_id, model, system_prompt, category_id, user_id, enabled, created_at) VALUES
 ('Assistant', (SELECT id FROM ai_providers WHERE slug = 'anthropic'), '',
  'You are the forum assistant. Keep replies short, clear, and polite.', NULL,
  (SELECT id FROM users WHERE username = 'assistant_$BOT_SUFFIX'), 0, strftime('%s','now'));
SQL
  chown "$SVC_USER:$SVC_USER" "$DB"* 2>/dev/null || true
  chmod 0600 "$DB"* 2>/dev/null || true
  ok "Seed data (categories, admin, AI providers, default profile)"
}

verify_site() {
  sleep 2
  local base="http://127.0.0.1:$HTTP_PORT" path
  for path in "/" "/category.php?slug=general" "/login.php" "/register.php" "/activity.php" "/stats.php" "/forgot-password.php" "/admin.php"; do
    if curl -fsS -H "Host: $DOMAIN" "$base$path" -o /dev/null 2>/dev/null; then
      ok "HTTP $path"
    else
      warn "HTTP $path FAILED. Check $LOG_DIR/error.log"
    fi
  done
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
  Port   : $HTTP_PORT
  Tunnel : $(if [[ $CF_NAMED -eq 1 ]]; then [[ $CF_LOGIN -eq 1 ]] && echo login || echo named; elif [[ $CLOUDFLARED -eq 1 ]]; then echo quick; else echo none; fi)
EOF
  exit 0
}

# ---- Flow ----
preflight
detect_os
install_packages
create_user
create_dirs
gen_secrets
init_sqlite
write_i18n
write_app
write_views
write_public
seed_data
setup_backups
setup_ai_cron
write_phpfpm
setup_ufw
setup_fail2ban
setup_sysctl
setup_tls
write_nginx
start_services
setup_cloudflared
setup_cf_named
setup_cf_login
compute_public_base
write_env
verify_site

CRED_FILE="/root/liteforum-credentials.txt"
install -m 0600 /dev/null "$CRED_FILE"
cat > "$CRED_FILE" <<EOF
LiteForum Installation
======================
URL             : $PUBLIC_BASE
Tunnel          : $(if [[ $CF_NAMED -eq 1 ]]; then echo "cloudflared named tunnel (TLS at Cloudflare)"; elif [[ $CLOUDFLARED -eq 1 ]]; then echo "cloudflared quick tunnel (URL changes on restart)"; else echo none; fi)
Install lang    : $LANG_CODE
Admin email     : $ADMIN_EMAIL
Admin password  : $ADMIN_PASS
App key         : $APP_KEY
DB              : $DATA_DIR/liteforum.db
Logs            : $LOG_DIR
EOF
chmod 0600 "$CRED_FILE"

echo
echo "============================================================"
echo " LiteForum ready → $PUBLIC_BASE"
echo " Admin: $ADMIN_EMAIL / $ADMIN_PASS"
echo " Credentials: $CRED_FILE"
echo "============================================================"
