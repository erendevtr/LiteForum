#!/usr/bin/env bash
# =============================================================================
# LiteForum — Complete One-Shot Installer (v3 — All Features)
# =============================================================================
set -Eeuo pipefail
umask 027

DOMAIN=""; ADMIN_EMAIL=""; EMAIL=""
LANG_CODE="tr"
DRY_RUN=0; SKIP_TLS=0; NO_FIREWALL=0; CLOUDFLARED=0
CF_TOKEN=""; CF_LOGIN=0; CF_NAMED=0
APP_DIR="/var/www/liteforum"; DATA_DIR="/var/lib/liteforum"; LOG_DIR="/var/log/liteforum"
SVC_USER="liteforum"; PHP_VER=""; INSTALL_LOG="/var/log/liteforum-install.log"

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
EOT
exit 0; }

while [[ $# -gt 0 ]]; do case "$1" in
  --domain) DOMAIN="$2"; shift 2;; --email) EMAIL="$2"; shift 2;;
  --admin) ADMIN_EMAIL="$2"; shift 2;; --lang) LANG_CODE="$2"; shift 2;;
  --skip-tls) SKIP_TLS=1; shift;; --no-firewall) NO_FIREWALL=1; shift;;
  --dry-run) DRY_RUN=1; shift;; --cloudflared) CLOUDFLARED=1; shift;;
  --cf-token) CF_TOKEN="$2"; shift 2;; --cf-login) CF_LOGIN=1; shift;;
  -h|--help) usage;;
  *) die "Unknown arg: $1";;
esac; done

[[ "$LANG_CODE" == "tr" || "$LANG_CODE" == "en" ]] || die "--lang must be tr|en"
[[ $EUID -eq 0 ]] || die "root required"
if [[ -n "$CF_TOKEN" && $CF_LOGIN -eq 1 ]]; then
  die "Use either --cf-token or --cf-login, not both"
fi
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
  if ! apt-get install -y -qq \
      nginx nginx-common \
      "$PHP_VER-fpm" "$PHP_VER-cli" "$PHP_VER-sqlite3" "$PHP_VER-curl" \
      "$PHP_VER-mbstring" "$PHP_VER-xml" "$PHP_VER-intl" "$PHP_VER-opcache" \
      "$PHP_VER-bcmath" "$PHP_VER-gd" \
      sqlite3 curl ca-certificates openssl \
      ufw fail2ban unattended-upgrades \
      certbot python3-certbot-nginx logrotate rsync jq; then
    die "Package install failed"
  fi
  apt-get install -y -qq libnginx-mod-http-headers-more-filter libnginx-mod-http-limit-req 2>/dev/null || true
  command -v nginx   >/dev/null || die "nginx binary missing"
  command -v sqlite3 >/dev/null || die "sqlite3 missing"
  command -v php     >/dev/null || die "php missing"
  install -d -o root -g root -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
  ok "Packages installed ($PHP_VER)"
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

CREATE TABLE settings(
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

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
SQL
  sqlite3 "$DB" "INSERT INTO settings(key,value) VALUES('app_name','LiteForum'),('app_tagline','A lightweight, modern forum');"
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
    'rate_limit' => ['login_per_10min'=>10, 'post_per_min'=>6, 'register_per_hr'=>5, 'react_per_min'=>30, 'reset_per_hr'=>3],
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
  'username'=>'Kullanıcı adı','email'=>'E-posta','password'=>'Şifre','bio'=>'Hakkında',
  'categories'=>'Kategoriler','topics'=>'Konular','posts'=>'Mesajlar','views'=>'Görüntüleme',
  'new_topic'=>'Yeni Konu','reply'=>'Yanıtla','search'=>'Ara...','submit'=>'Gönder',
  'notifications'=>'Bildirimler','mark_all_read'=>'Tümünü okundu işaretle','no_notifications'=>'Bildirim yok',
  'watch_topic'=>'Konuyu takip et','unwatch_topic'=>'Takibi bırak',
  'theme'=>'Tema','accent'=>'Vurgu rengi','settings'=>'Ayarlar','save'=>'Kaydet',
  'search_results'=>'Arama sonuçları','no_results'=>'Sonuç yok','search_placeholder'=>'Ara...',
  'home'=>'Ana Sayfa','activity'=>'Son Aktivite','stats'=>'İstatistikler','profile'=>'Profil',
  'recent_topics'=>'Son Konular','latest_posts'=>'Son Mesajlar','online_users'=>'Çevrimiçi',
  'members'=>'Üyeler','total_topics'=>'Konular','total_posts'=>'Mesajlar','total_users'=>'Üyeler',
  'joined'=>'Katılım','last_seen'=>'Son görülme','reply_to_topic'=>'Konuya yanıt ver',
  'title'=>'Başlık','body'=>'İçerik','post_reply'=>'Yanıtla','back'=>'Geri',
  'erendev_login'=>'ErenDev ile Giriş Yap',
  'too_many_attempts'=>'Çok fazla deneme.','missing_info'=>'Eksik bilgi.',
  'bad_credentials'=>'E-posta veya şifre hatalı.','bot_detected'=>'Bot tespit edildi.',
  'register_limit'=>'Kayıt limiti aşıldı.','bad_username'=>'Kullanıcı adı 3-32 karakter olmalı.',
  'bad_email'=>'Geçerli e-posta girin.','weak_password'=>'Şifre en az 10 karakter.',
  'already_exists'=>'Zaten kayıtlı.','saved'=>'Kaydedildi.','not_found'=>'Bulunamadı.',
  'settings_saved'=>'Ayarlar kaydedildi.','profile_updated'=>'Profil güncellendi.',
  'site_name'=>'Site adı','site_tagline'=>'Site sloganı','admin_settings'=>'Site Ayarları',
  'admin_users'=>'Kullanıcılar','admin_audit'=>'Denetim Kaydı','roles'=>'Roller',
  'admin_categories'=>'Kategori Yönetimi','add_category'=>'Kategori Ekle',
  'edit_category'=>'Kategoriyi Düzenle','delete_category'=>'Kategoriyi Sil',
  'delete_confirm'=>'Silmek istediğinizden emin misiniz?','yes_delete'=>'Evet, sil',
  'no_topics_yet'=>'Henüz konu yok.','loading'=>'Yükleniyor...','delete'=>'Sil','edit'=>'Düzenle',
  'slug'=>'Kısa ad (slug)','icon'=>'Simge','position'=>'Sıra','description'=>'Açıklama',
  'password_change'=>'Şifre Değiştir','current_password'=>'Mevcut şifre',
  'new_password'=>'Yeni şifre','confirm_password'=>'Yeni şifre (tekrar)',
  'password_changed'=>'Şifre güncellendi.','password_mismatch'=>'Şifreler eşleşmiyor.',
  'password_wrong'=>'Mevcut şifre yanlış.','email_change'=>'E-posta Değiştir',
  'forgot_password'=>'Şifremi unuttum','reset_password'=>'Şifreyi sıfırla',
  'reset_link_sent'=>'E-posta adresinize sıfırlama bağlantısı gönderildi (eğer kayıtlıysa).',
  'reset_invalid'=>'Bağlantı geçersiz veya süresi dolmuş.','reset_complete'=>'Şifre sıfırlandı. Giriş yapabilirsiniz.',
  'pin'=>'Sabitle','unpin'=>'Sabitlemeyi kaldır',
  'lock'=>'Kilitle','unlock'=>'Kilidi aç',
  'delete_post'=>'Mesajı sil','delete_topic'=>'Konuyu sil',
  'ban_user'=>'Kullanıcıyı Yasakla','unban_user'=>'Yasağı Kaldır',
  'banned'=>'Yasaklandı','ban_reason'=>'Yasak nedeni',
  'mod_actions'=>'Moderatör İşlemleri','mod_only'=>'Bu işlem için yetkiniz yok.',
  'reaction'=>'Tepki','reacted_to'=>'tepki verdi',
  'edited'=>'düzenlendi','deleted_post'=>'[silindi]',
  'latest'=>'En Son','popular'=>'Popüler','no_more'=>'Başka yok',
  'email_taken'=>'Bu e-posta kullanılıyor.','invalid_token'=>'Geçersiz token.',
  'post_too_fast'=>'Çok hızlı yazıyorsunuz.','banned_msg'=>'Hesabınız yasaklanmış.',
];
PHP
  cat > "$APP_DIR/lang/en.php" <<'PHP'
<?php return [
  'forum'=>'Forum','login'=>'Log in','register'=>'Sign up','logout'=>'Log out',
  'username'=>'Username','email'=>'Email','password'=>'Password','bio'=>'Bio',
  'categories'=>'Categories','topics'=>'Topics','posts'=>'Posts','views'=>'Views',
  'new_topic'=>'New topic','reply'=>'Reply','search'=>'Search...','submit'=>'Submit',
  'notifications'=>'Notifications','mark_all_read'=>'Mark all as read','no_notifications'=>'No notifications',
  'watch_topic'=>'Watch topic','unwatch_topic'=>'Unwatch',
  'theme'=>'Theme','accent'=>'Accent color','settings'=>'Settings','save'=>'Save',
  'search_results'=>'Search results','no_results'=>'No results','search_placeholder'=>'Search...',
  'home'=>'Home','activity'=>'Activity','stats'=>'Statistics','profile'=>'Profile',
  'recent_topics'=>'Recent Topics','latest_posts'=>'Latest Posts','online_users'=>'Online',
  'members'=>'Members','total_topics'=>'Topics','total_posts'=>'Posts','total_users'=>'Members',
  'joined'=>'Joined','last_seen'=>'Last seen','reply_to_topic'=>'Reply to topic',
  'title'=>'Title','body'=>'Body','post_reply'=>'Reply','back'=>'Back',
  'erendev_login'=>'Sign in with ErenDev',
  'too_many_attempts'=>'Too many attempts.','missing_info'=>'Missing information.',
  'bad_credentials'=>'Incorrect email or password.','bot_detected'=>'Bot detected.',
  'register_limit'=>'Registration limit exceeded.','bad_username'=>'Username must be 3-32 chars.',
  'bad_email'=>'Enter a valid email.','weak_password'=>'Password min 10 chars.',
  'already_exists'=>'Already registered.','saved'=>'Saved.','not_found'=>'Not found.',
  'settings_saved'=>'Settings saved.','profile_updated'=>'Profile updated.',
  'site_name'=>'Site name','site_tagline'=>'Site tagline','admin_settings'=>'Site Settings',
  'admin_users'=>'Users','admin_audit'=>'Audit Log','roles'=>'Roles',
  'admin_categories'=>'Category Management','add_category'=>'Add Category',
  'edit_category'=>'Edit Category','delete_category'=>'Delete Category',
  'delete_confirm'=>'Are you sure you want to delete?','yes_delete'=>'Yes, delete',
  'no_topics_yet'=>'No topics yet.','loading'=>'Loading...','delete'=>'Delete','edit'=>'Edit',
  'slug'=>'Slug','icon'=>'Icon','position'=>'Position','description'=>'Description',
  'password_change'=>'Change Password','current_password'=>'Current password',
  'new_password'=>'New password','confirm_password'=>'New password (again)',
  'password_changed'=>'Password updated.','password_mismatch'=>'Passwords do not match.',
  'password_wrong'=>'Current password is incorrect.','email_change'=>'Change Email',
  'forgot_password'=>'Forgot password','reset_password'=>'Reset password',
  'reset_link_sent'=>'A reset link has been sent (if the address is registered).',
  'reset_invalid'=>'Link is invalid or expired.','reset_complete'=>'Password reset. You can now log in.',
  'pin'=>'Pin','unpin'=>'Unpin',
  'lock'=>'Lock','unlock'=>'Unlock',
  'delete_post'=>'Delete post','delete_topic'=>'Delete topic',
  'ban_user'=>'Ban user','unban_user'=>'Unban user',
  'banned'=>'Banned','ban_reason'=>'Ban reason',
  'mod_actions'=>'Moderator Actions','mod_only'=>'You do not have permission.',
  'reaction'=>'Reaction','reacted_to'=>'reacted to',
  'edited'=>'edited','deleted_post'=>'[deleted]',
  'latest'=>'Latest','popular'=>'Popular','no_more'=>'No more',
  'email_taken'=>'Email already in use.','invalid_token'=>'Invalid token.',
  'post_too_fast'=>'You are posting too fast.','banned_msg'=>'Your account is banned.',
];
PHP
  cat > "$APP_DIR/lang/fr.php" <<'PHP'
<?php return [
  'forum'=>'Forum','login'=>'Se connecter','register'=>"S'inscrire",'logout'=>'Se déconnecter',
  'username'=>"Nom d'utilisateur",'email'=>'E-mail','password'=>'Mot de passe','bio'=>'Bio',
  'categories'=>'Catégories','topics'=>'Sujets','posts'=>'Messages','views'=>'Vues',
  'new_topic'=>'Nouveau sujet','reply'=>'Répondre','search'=>'Rechercher...','submit'=>'Envoyer',
  'notifications'=>'Notifications','mark_all_read'=>'Tout marquer comme lu','no_notifications'=>'Aucune notification',
  'watch_topic'=>'Suivre','unwatch_topic'=>'Ne plus suivre',
  'theme'=>'Thème','accent'=>"Couleur d'accent",'settings'=>'Paramètres','save'=>'Enregistrer',
  'search_results'=>'Résultats','no_results'=>'Aucun résultat','search_placeholder'=>'Rechercher...',
  'home'=>'Accueil','activity'=>'Activité','stats'=>'Statistiques','profile'=>'Profil',
  'recent_topics'=>'Sujets récents','latest_posts'=>'Messages récents','online_users'=>'En ligne',
  'members'=>'Membres','total_topics'=>'Sujets','total_posts'=>'Messages','total_users'=>'Membres',
  'joined'=>'Inscrit','last_seen'=>'Vu','reply_to_topic'=>'Répondre',
  'title'=>'Titre','body'=>'Contenu','post_reply'=>'Répondre','back'=>'Retour',
  'erendev_login'=>'Se connecter avec ErenDev',
  'too_many_attempts'=>'Trop de tentatives.','missing_info'=>'Informations manquantes.',
  'bad_credentials'=>'E-mail ou mot de passe incorrect.','bot_detected'=>'Bot détecté.',
  'register_limit'=>"Limite d'inscription atteinte.",'bad_username'=>"Nom 3-32 caractères.",
  'bad_email'=>'E-mail invalide.','weak_password'=>'Mot de passe min 10 caractères.',
  'already_exists'=>'Déjà inscrit.','saved'=>'Enregistré.','not_found'=>'Introuvable.',
  'settings_saved'=>'Paramètres enregistrés.','profile_updated'=>'Profil mis à jour.',
  'site_name'=>'Nom du site','site_tagline'=>'Slogan','admin_settings'=>'Paramètres du site',
  'admin_users'=>'Utilisateurs','admin_audit'=>'Journal','roles'=>'Rôles',
  'admin_categories'=>'Gestion des catégories','add_category'=>'Ajouter une catégorie',
  'edit_category'=>'Modifier','delete_category'=>'Supprimer',
  'delete_confirm'=>'Confirmer la suppression ?','yes_delete'=>'Oui, supprimer',
  'no_topics_yet'=>'Aucun sujet.','loading'=>'Chargement...','delete'=>'Supprimer','edit'=>'Modifier',
  'slug'=>'Slug','icon'=>'Icône','position'=>'Position','description'=>'Description',
  'password_change'=>'Changer le mot de passe','current_password'=>'Mot de passe actuel',
  'new_password'=>'Nouveau mot de passe','confirm_password'=>'Confirmer',
  'password_changed'=>'Mot de passe mis à jour.','password_mismatch'=>'Les mots de passe ne correspondent pas.',
  'password_wrong'=>'Mot de passe actuel incorrect.','email_change'=>'Changer e-mail',
  'forgot_password'=>'Mot de passe oublié','reset_password'=>'Réinitialiser',
  'reset_link_sent'=>'Un lien de réinitialisation a été envoyé.',
  'reset_invalid'=>'Lien invalide ou expiré.','reset_complete'=>'Mot de passe réinitialisé.',
  'pin'=>'Épingler','unpin'=>'Détacher','lock'=>'Verrouiller','unlock'=>'Déverrouiller',
  'delete_post'=>'Supprimer le message','delete_topic'=>'Supprimer le sujet',
  'ban_user'=>'Bannir','unban_user'=>'Débannir','banned'=>'Banni','ban_reason'=>'Raison du ban',
  'mod_actions'=>'Actions modérateur','mod_only'=>'Permission refusée.',
  'reaction'=>'Réaction','reacted_to'=>'a réagi à','edited'=>'modifié','deleted_post'=>'[supprimé]',
  'latest'=>'Récent','popular'=>'Populaire','no_more'=>'Plus rien',
  'email_taken'=>'E-mail déjà utilisé.','invalid_token'=>'Jeton invalide.',
  'post_too_fast'=>'Trop rapide.','banned_msg'=>'Compte banni.',
];
PHP
  cat > "$APP_DIR/lang/de.php" <<'PHP'
<?php return [
  'forum'=>'Forum','login'=>'Anmelden','register'=>'Registrieren','logout'=>'Abmelden',
  'username'=>'Benutzername','email'=>'E-Mail','password'=>'Passwort','bio'=>'Über mich',
  'categories'=>'Kategorien','topics'=>'Themen','posts'=>'Beiträge','views'=>'Aufrufe',
  'new_topic'=>'Neues Thema','reply'=>'Antworten','search'=>'Suchen...','submit'=>'Absenden',
  'notifications'=>'Benachrichtigungen','mark_all_read'=>'Alle als gelesen markieren','no_notifications'=>'Keine Benachrichtigungen',
  'watch_topic'=>'Beobachten','unwatch_topic'=>'Nicht mehr beobachten',
  'theme'=>'Design','accent'=>'Akzentfarbe','settings'=>'Einstellungen','save'=>'Speichern',
  'search_results'=>'Suchergebnisse','no_results'=>'Keine Ergebnisse','search_placeholder'=>'Suchen...',
  'home'=>'Startseite','activity'=>'Aktivität','stats'=>'Statistik','profile'=>'Profil',
  'recent_topics'=>'Neueste Themen','latest_posts'=>'Neueste Beiträge','online_users'=>'Online',
  'members'=>'Mitglieder','total_topics'=>'Themen','total_posts'=>'Beiträge','total_users'=>'Mitglieder',
  'joined'=>'Beigetreten','last_seen'=>'Zuletzt gesehen','reply_to_topic'=>'Antworten',
  'title'=>'Titel','body'=>'Inhalt','post_reply'=>'Antworten','back'=>'Zurück',
  'erendev_login'=>'Mit ErenDev anmelden',
  'too_many_attempts'=>'Zu viele Versuche.','missing_info'=>'Fehlende Angaben.',
  'bad_credentials'=>'E-Mail oder Passwort falsch.','bot_detected'=>'Bot erkannt.',
  'register_limit'=>'Registrierungslimit erreicht.','bad_username'=>'Benutzername 3-32 Zeichen.',
  'bad_email'=>'Ungültige E-Mail.','weak_password'=>'Passwort min 10 Zeichen.',
  'already_exists'=>'Bereits registriert.','saved'=>'Gespeichert.','not_found'=>'Nicht gefunden.',
  'settings_saved'=>'Einstellungen gespeichert.','profile_updated'=>'Profil aktualisiert.',
  'site_name'=>'Seitenname','site_tagline'=>'Slogan','admin_settings'=>'Seiteneinstellungen',
  'admin_users'=>'Benutzer','admin_audit'=>'Audit-Protokoll','roles'=>'Rollen',
  'admin_categories'=>'Kategorienverwaltung','add_category'=>'Kategorie hinzufügen',
  'edit_category'=>'Bearbeiten','delete_category'=>'Löschen',
  'delete_confirm'=>'Wirklich löschen?','yes_delete'=>'Ja, löschen',
  'no_topics_yet'=>'Noch keine Themen.','loading'=>'Lädt...','delete'=>'Löschen','edit'=>'Bearbeiten',
  'slug'=>'Slug','icon'=>'Symbol','position'=>'Position','description'=>'Beschreibung',
  'password_change'=>'Passwort ändern','current_password'=>'Aktuelles Passwort',
  'new_password'=>'Neues Passwort','confirm_password'=>'Bestätigen',
  'password_changed'=>'Passwort aktualisiert.','password_mismatch'=>'Passwörter stimmen nicht überein.',
  'password_wrong'=>'Aktuelles Passwort falsch.','email_change'=>'E-Mail ändern',
  'forgot_password'=>'Passwort vergessen','reset_password'=>'Zurücksetzen',
  'reset_link_sent'=>'Zurücksetzungslink gesendet.','reset_invalid'=>'Link ungültig oder abgelaufen.',
  'reset_complete'=>'Passwort zurückgesetzt.','pin'=>'Anheften','unpin'=>'Lösen',
  'lock'=>'Sperren','unlock'=>'Entsperren',
  'delete_post'=>'Beitrag löschen','delete_topic'=>'Thema löschen',
  'ban_user'=>'Sperren','unban_user'=>'Entsperren','banned'=>'Gesperrt','ban_reason'=>'Grund',
  'mod_actions'=>'Moderator-Aktionen','mod_only'=>'Keine Berechtigung.',
  'reaction'=>'Reaktion','reacted_to'=>'reagierte auf','edited'=>'bearbeitet','deleted_post'=>'[gelöscht]',
  'latest'=>'Neueste','popular'=>'Beliebt','no_more'=>'Nichts mehr',
  'email_taken'=>'E-Mail bereits verwendet.','invalid_token'=>'Ungültiger Token.',
  'post_too_fast'=>'Zu schnell.','banned_msg'=>'Konto gesperrt.',
];
PHP
  cat > "$APP_DIR/lang/es.php" <<'PHP'
<?php return [
  'forum'=>'Foro','login'=>'Iniciar sesión','register'=>'Registrarse','logout'=>'Cerrar sesión',
  'username'=>'Usuario','email'=>'Correo','password'=>'Contraseña','bio'=>'Biografía',
  'categories'=>'Categorías','topics'=>'Temas','posts'=>'Mensajes','views'=>'Vistas',
  'new_topic'=>'Nuevo tema','reply'=>'Responder','search'=>'Buscar...','submit'=>'Enviar',
  'notifications'=>'Notificaciones','mark_all_read'=>'Marcar todo como leído','no_notifications'=>'Sin notificaciones',
  'watch_topic'=>'Seguir','unwatch_topic'=>'Dejar de seguir',
  'theme'=>'Tema','accent'=>'Color de acento','settings'=>'Ajustes','save'=>'Guardar',
  'search_results'=>'Resultados','no_results'=>'Sin resultados','search_placeholder'=>'Buscar...',
  'home'=>'Inicio','activity'=>'Actividad','stats'=>'Estadísticas','profile'=>'Perfil',
  'recent_topics'=>'Temas recientes','latest_posts'=>'Últimos mensajes','online_users'=>'En línea',
  'members'=>'Miembros','total_topics'=>'Temas','total_posts'=>'Mensajes','total_users'=>'Miembros',
  'joined'=>'Registrado','last_seen'=>'Visto','reply_to_topic'=>'Responder',
  'title'=>'Título','body'=>'Contenido','post_reply'=>'Responder','back'=>'Volver',
  'erendev_login'=>'Iniciar sesión con ErenDev',
  'too_many_attempts'=>'Demasiados intentos.','missing_info'=>'Información incompleta.',
  'bad_credentials'=>'Correo o contraseña incorrectos.','bot_detected'=>'Bot detectado.',
  'register_limit'=>'Límite alcanzado.','bad_username'=>'Usuario 3-32 caracteres.',
  'bad_email'=>'Correo inválido.','weak_password'=>'Contraseña min 10 caracteres.',
  'already_exists'=>'Ya registrado.','saved'=>'Guardado.','not_found'=>'No encontrado.',
  'settings_saved'=>'Ajustes guardados.','profile_updated'=>'Perfil actualizado.',
  'site_name'=>'Nombre','site_tagline'=>'Lema','admin_settings'=>'Ajustes del sitio',
  'admin_users'=>'Usuarios','admin_audit'=>'Auditoría','roles'=>'Roles',
  'admin_categories'=>'Gestión de categorías','add_category'=>'Añadir',
  'edit_category'=>'Editar','delete_category'=>'Eliminar',
  'delete_confirm'=>'¿Confirmar eliminación?','yes_delete'=>'Sí, eliminar',
  'no_topics_yet'=>'Sin temas.','loading'=>'Cargando...','delete'=>'Eliminar','edit'=>'Editar',
  'slug'=>'Slug','icon'=>'Icono','position'=>'Posición','description'=>'Descripción',
  'password_change'=>'Cambiar contraseña','current_password'=>'Contraseña actual',
  'new_password'=>'Nueva contraseña','confirm_password'=>'Confirmar',
  'password_changed'=>'Contraseña actualizada.','password_mismatch'=>'No coinciden.',
  'password_wrong'=>'Contraseña actual incorrecta.','email_change'=>'Cambiar correo',
  'forgot_password'=>'Olvidé mi contraseña','reset_password'=>'Restablecer',
  'reset_link_sent'=>'Enlace enviado.','reset_invalid'=>'Enlace inválido o expirado.',
  'reset_complete'=>'Contraseña restablecida.','pin'=>'Fijar','unpin'=>'Quitar fijación',
  'lock'=>'Bloquear','unlock'=>'Desbloquear',
  'delete_post'=>'Eliminar mensaje','delete_topic'=>'Eliminar tema',
  'ban_user'=>'Banear','unban_user'=>'Desbanear','banned'=>'Baneado','ban_reason'=>'Motivo',
  'mod_actions'=>'Acciones de moderador','mod_only'=>'Sin permiso.',
  'reaction'=>'Reacción','reacted_to'=>'reaccionó a','edited'=>'editado','deleted_post'=>'[eliminado]',
  'latest'=>'Recientes','popular'=>'Populares','no_more'=>'No hay más',
  'email_taken'=>'Correo ya en uso.','invalid_token'=>'Token inválido.',
  'post_too_fast'=>'Demasiado rápido.','banned_msg'=>'Cuenta baneada.',
];
PHP
  cat > "$APP_DIR/lang/ar.php" <<'PHP'
<?php return [
  'forum'=>'المنتدى','login'=>'تسجيل الدخول','register'=>'إنشاء حساب','logout'=>'تسجيل الخروج',
  'username'=>'اسم المستخدم','email'=>'البريد الإلكتروني','password'=>'كلمة المرور','bio'=>'نبذة',
  'categories'=>'الأقسام','topics'=>'المواضيع','posts'=>'المنشورات','views'=>'المشاهدات',
  'new_topic'=>'موضوع جديد','reply'=>'رد','search'=>'بحث...','submit'=>'إرسال',
  'notifications'=>'الإشعارات','mark_all_read'=>'تحديد الكل كمقروء','no_notifications'=>'لا توجد إشعارات',
  'watch_topic'=>'متابعة','unwatch_topic'=>'إلغاء المتابعة',
  'theme'=>'المظهر','accent'=>'لون التمييز','settings'=>'الإعدادات','save'=>'حفظ',
  'search_results'=>'نتائج البحث','no_results'=>'لا نتائج','search_placeholder'=>'بحث...',
  'home'=>'الرئيسية','activity'=>'النشاط','stats'=>'الإحصاءات','profile'=>'الملف',
  'recent_topics'=>'المواضيع الأخيرة','latest_posts'=>'أحدث المنشورات','online_users'=>'متصل',
  'members'=>'الأعضاء','total_topics'=>'المواضيع','total_posts'=>'المنشورات','total_users'=>'الأعضاء',
  'joined'=>'الانضمام','last_seen'=>'آخر ظهور','reply_to_topic'=>'رد',
  'title'=>'العنوان','body'=>'المحتوى','post_reply'=>'رد','back'=>'رجوع',
  'erendev_login'=>'تسجيل الدخول عبر ErenDev',
  'too_many_attempts'=>'محاولات كثيرة.','missing_info'=>'معلومات ناقصة.',
  'bad_credentials'=>'البريد أو كلمة المرور غير صحيحة.','bot_detected'=>'تم رصد روبوت.',
  'register_limit'=>'تجاوز حد التسجيل.','bad_username'=>'اسم المستخدم 3-32 حرفًا.',
  'bad_email'=>'بريد غير صالح.','weak_password'=>'كلمة المرور 10 أحرف على الأقل.',
  'already_exists'=>'مسجل بالفعل.','saved'=>'تم الحفظ.','not_found'=>'غير موجود.',
  'settings_saved'=>'تم حفظ الإعدادات.','profile_updated'=>'تم التحديث.',
  'site_name'=>'اسم الموقع','site_tagline'=>'شعار','admin_settings'=>'إعدادات الموقع',
  'admin_users'=>'المستخدمون','admin_audit'=>'سجل التدقيق','roles'=>'الأدوار',
  'admin_categories'=>'إدارة الأقسام','add_category'=>'إضافة قسم',
  'edit_category'=>'تعديل','delete_category'=>'حذف',
  'delete_confirm'=>'تأكيد الحذف؟','yes_delete'=>'نعم، احذف',
  'no_topics_yet'=>'لا مواضيع.','loading'=>'جار التحميل...','delete'=>'حذف','edit'=>'تعديل',
  'slug'=>'الرابط','icon'=>'الأيقونة','position'=>'الترتيب','description'=>'الوصف',
  'password_change'=>'تغيير كلمة المرور','current_password'=>'كلمة المرور الحالية',
  'new_password'=>'كلمة المرور الجديدة','confirm_password'=>'تأكيد',
  'password_changed'=>'تم تحديث كلمة المرور.','password_mismatch'=>'كلمتا المرور غير متطابقتين.',
  'password_wrong'=>'كلمة المرور الحالية خاطئة.','email_change'=>'تغيير البريد',
  'forgot_password'=>'نسيت كلمة المرور','reset_password'=>'إعادة تعيين',
  'reset_link_sent'=>'تم إرسال رابط إعادة التعيين.','reset_invalid'=>'رابط غير صالح أو منتهي.',
  'reset_complete'=>'تم إعادة تعيين كلمة المرور.','pin'=>'تثبيت','unpin'=>'إلغاء التثبيت',
  'lock'=>'قفل','unlock'=>'فتح',
  'delete_post'=>'حذف المنشور','delete_topic'=>'حذف الموضوع',
  'ban_user'=>'حظر','unban_user'=>'رفع الحظر','banned'=>'محظور','ban_reason'=>'سبب الحظر',
  'mod_actions'=>'إجراءات المشرف','mod_only'=>'لا تملك الصلاحية.',
  'reaction'=>'تفاعل','reacted_to'=>'تفاعل مع','edited'=>'معدل','deleted_post'=>'[محذوف]',
  'latest'=>'الأحدث','popular'=>'الأكثر شعبية','no_more'=>'لا المزيد',
  'email_taken'=>'البريد مستخدم بالفعل.','invalid_token'=>'رمز غير صالح.',
  'post_too_fast'=>'نشر سريع جدًا.','banned_msg'=>'حسابك محظور.',
];
PHP
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
require LF_ROOT . '/app/settings.php';
require LF_ROOT . '/app/flash.php';
require LF_ROOT . '/app/markdown.php';
require LF_ROOT . '/app/avatar.php';
require LF_ROOT . '/app/activity.php';
require LF_ROOT . '/app/mail.php';

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
$GLOBALS['__app_name'] = settings_get($db, 'app_name', 'LiteForum');
$GLOBALS['__app_tagline'] = settings_get($db, 'app_tagline', '');

if (!empty($_SESSION['user']['id'])) {
  $st = $db->prepare('SELECT banned, ban_reason FROM users WHERE id=?');
  $st->execute([(int)$_SESSION['user']['id']]);
  $u = $st->fetch();
  if ($u && (int)$u['banned'] === 1) {
    $_SESSION['user'] = null;
    session_destroy();
    http_response_code(403);
    die(t('banned_msg'));
  }
  $db->prepare('UPDATE users SET last_seen_at=? WHERE id=?')->execute([time(), (int)$_SESSION['user']['id']]);
}
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
function time_ago(int $ts): string {
  $d = time() - $ts;
  if ($d < 60) return $d . 's';
  if ($d < 3600) return floor($d/60) . 'm';
  if ($d < 86400) return floor($d/3600) . 'h';
  if ($d < 2592000) return floor($d/86400) . 'd';
  return date('Y-m-d', $ts);
}
function cat_name(array $cat, string $lc): string {
  $k = 'name_' . $lc;
  return $cat[$k] ?? $cat['name_en'] ?? $cat['name_tr'] ?? '';
}
function cat_desc(array $cat, string $lc): string {
  $k = 'description_' . $lc;
  return $cat[$k] ?? $cat['description_en'] ?? $cat['description_tr'] ?? '';
}
function is_mod(?array $u): bool {
  return $u !== null && in_array($u['role'], ['moderator','admin'], true);
}
function is_admin(?array $u): bool {
  return $u !== null && $u['role'] === 'admin';
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
function auth_require(): array { $u=auth_user(); if (!$u) redirect('/login.php?next=' . urlencode($_SERVER['REQUEST_URI'] ?? '/')); return $u; }
function auth_admin(): array { $u=auth_require(); if (!is_admin($u)) { http_response_code(403); exit(t('mod_only')); } return $u; }
function auth_mod(): array { $u=auth_require(); if (!is_mod($u)) { http_response_code(403); exit(t('mod_only')); } return $u; }
function auth_login(array $u): void {
  session_regenerate_id(true);
  $_SESSION['user'] = [
    'id' => (int)$u['id'],
    'username' => $u['username'],
    'role' => $u['role'],
    'theme' => $u['theme'] ?? 'dark',
    'accent' => $u['accent'] ?? 'indigo',
    'bio' => $u['bio'] ?? '',
    'avatar_color' => $u['avatar_color'] ?? '#6366f1',
    'notify_mentions' => (int)($u['notify_mentions'] ?? 1),
    'notify_replies' => (int)($u['notify_replies'] ?? 1),
    'notify_reactions' => (int)($u['notify_reactions'] ?? 1),
    'notify_digest' => (int)($u['notify_digest'] ?? 0),
  ];
  $GLOBALS['db']->prepare('UPDATE users SET last_login_at=?, last_seen_at=? WHERE id=?')
                ->execute([time(), time(), (int)$u['id']]);
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
  $GLOBALS['__lang_code'] = $code;
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
    'indigo'  => ['500'=>'#6366f1','600'=>'#4f46e5','400'=>'#818cf8','glow'=>'rgba(79,70,229,.25)'],
    'emerald' => ['500'=>'#10b981','600'=>'#059669','400'=>'#34d399','glow'=>'rgba(16,185,129,.25)'],
    'rose'    => ['500'=>'#f43f5e','600'=>'#e11d48','400'=>'#fb7185','glow'=>'rgba(244,63,94,.25)'],
    'amber'   => ['500'=>'#f59e0b','600'=>'#d97706','400'=>'#fbbf24','glow'=>'rgba(245,158,11,.25)'],
    'sky'     => ['500'=>'#0ea5e9','600'=>'#0284c7','400'=>'#38bdf8','glow'=>'rgba(14,165,233,.25)'],
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
  $db->prepare('INSERT INTO notifications(user_id,kind,topic_id,post_id,actor_id,snippet,created_at) VALUES(?,?,?,?,?,?,?)')
     ->execute([$userId,$kind,$topicId,$postId,$actorId,mb_substr($snippet,0,140),time()]);
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
  $st = $db->prepare('SELECT w.user_id, u.notify_replies FROM topic_watches w JOIN users u ON u.id=w.user_id WHERE w.topic_id=? AND w.user_id!=?');
  $st->execute([$topicId, $actorId]);
  foreach ($st->fetchAll() as $r) {
    if ((int)$r['notify_replies'] === 1) notif_create($db, (int)$r['user_id'], 'reply', $topicId, $postId, $actorId, $body);
  }
}
function notif_for_reaction(PDO $db, int $postId, int $actorId, string $emoji): void {
  $st = $db->prepare('SELECT p.user_id, u.notify_reactions, p.topic_id, p.body, p.id FROM posts p JOIN users u ON u.id=p.user_id WHERE p.id=?');
  $st->execute([$postId]); $row = $st->fetch();
  if (!$row || (int)$row['user_id'] === $actorId) return;
  if ((int)$row['notify_reactions'] !== 1) return;
  notif_create($db, (int)$row['user_id'], 'reaction', (int)$row['topic_id'], $postId, $actorId, $emoji . ' ' . $row['body']);
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
function notif_mark_read(PDO $db, int $userId, int $notifId): void {
  $db->prepare('UPDATE notifications SET read_at=? WHERE id=? AND user_id=?')->execute([time(),$notifId,$userId]);
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
          WHERE posts_fts MATCH ? AND p.is_deleted = 0';
  $params = [$q];
  if ($categoryId) { $sql .= ' AND t.category_id = ?'; $params[] = $categoryId; }
  if ($authorId)   { $sql .= ' AND p.user_id = ?';     $params[] = $authorId; }
  $sql .= ' ORDER BY rank LIMIT ? OFFSET ?';
  $params[] = $per; $params[] = max(0, ($page-1)*$per);
  $st = $db->prepare($sql);
  try { $st->execute($params); } catch (PDOException $e) { return ['rows'=>[], 'total'=>0]; }
  $rows = $st->fetchAll();
  $csql = 'SELECT COUNT(*) FROM posts_fts JOIN posts p ON p.id=posts_fts.rowid JOIN topics t ON t.id=p.topic_id WHERE posts_fts MATCH ? AND p.is_deleted = 0';
  $cparams = [$q];
  if ($categoryId) { $csql .= ' AND t.category_id = ?'; $cparams[] = $categoryId; }
  if ($authorId)   { $csql .= ' AND p.user_id = ?';     $cparams[] = $authorId; }
  $cst = $db->prepare($csql); $cst->execute($cparams);
  return ['rows'=>$rows, 'total'=>(int)$cst->fetchColumn()];
}
PHP

  cat > "$APP_DIR/app/settings.php" <<'PHP'
<?php
declare(strict_types=1);
function settings_get(PDO $db, string $key, string $default=''): string {
  static $cache = [];
  if (isset($cache[$key])) return $cache[$key];
  $st = $db->prepare('SELECT value FROM settings WHERE key=?');
  $st->execute([$key]);
  $v = $st->fetchColumn();
  $cache[$key] = $v !== false ? (string)$v : $default;
  return $cache[$key];
}
function settings_set(PDO $db, string $key, string $value): void {
  $db->prepare('INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value')
     ->execute([$key, $value]);
  $GLOBALS['__app_name'] = settings_get($db, 'app_name', 'LiteForum');
}
PHP

  cat > "$APP_DIR/app/flash.php" <<'PHP'
<?php
declare(strict_types=1);
function flash_set(string $type, string $msg): void {
  $_SESSION['flash'] = ['type'=>$type, 'msg'=>$msg, 'ts'=>time()];
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
  return $html;
}
PHP

  cat > "$APP_DIR/app/avatar.php" <<'PHP'
<?php
declare(strict_types=1);
function user_avatar(string $username, string $color='#6366f1', int $size=32): string {
  $initial = mb_strtoupper(mb_substr($username, 0, 1));
  $c = e($color);
  $s = (int)$size;
  $f = (int)($s * 0.45);
  return "<span style=\"display:inline-flex;align-items:center;justify-content:center;width:{$s}px;height:{$s}px;border-radius:50%;background:linear-gradient(135deg,{$c},{$c}99);color:#fff;font-weight:700;font-size:{$f}px;flex-shrink:0\">{$initial}</span>";
}
PHP

  cat > "$APP_DIR/app/activity.php" <<'PHP'
<?php
declare(strict_types=1);
function online_count(PDO $db): int {
  $st = $db->query('SELECT COUNT(*) FROM users WHERE last_seen_at > ' . (time() - 900));
  return (int)$st->fetchColumn();
}
function recent_topics(PDO $db, int $limit=10): array {
  $st = $db->prepare('SELECT t.*, u.username, c.slug AS cat_slug,
    (SELECT COUNT(*) FROM posts p WHERE p.topic_id=t.id AND p.is_deleted=0) AS post_count
    FROM topics t JOIN users u ON u.id=t.user_id JOIN categories c ON c.id=t.category_id
    ORDER BY t.updated_at DESC LIMIT ?');
  $st->execute([$limit]);
  return $st->fetchAll();
}
function recent_posts(PDO $db, int $limit=10): array {
  $st = $db->prepare('SELECT p.*, u.username, t.title AS topic_title, t.id AS topic_id
    FROM posts p JOIN users u ON u.id=p.user_id JOIN topics t ON t.id=p.topic_id
    WHERE p.is_deleted=0 ORDER BY p.created_at DESC LIMIT ?');
  $st->execute([$limit]);
  return $st->fetchAll();
}
function forum_stats(PDO $db): array {
  return [
    'topics' => (int)$db->query('SELECT COUNT(*) FROM topics')->fetchColumn(),
    'posts'  => (int)$db->query('SELECT COUNT(*) FROM posts WHERE is_deleted=0')->fetchColumn(),
    'users'  => (int)$db->query('SELECT COUNT(*) FROM users')->fetchColumn(),
    'online' => online_count($db),
    'newest' => $db->query('SELECT username, created_at FROM users ORDER BY id DESC LIMIT 1')->fetch() ?: null,
  ];
}
PHP

  cat > "$APP_DIR/app/mail.php" <<'PHP'
<?php
declare(strict_types=1);
function send_mail(string $to, string $subject, string $body): bool {
  $from = $GLOBALS['__config']['admin_email'] ?? 'noreply@localhost';
  $headers = "From: LiteForum <$from>\r\n";
  $headers .= "Content-Type: text/plain; charset=UTF-8\r\n";
  $headers .= "MIME-Version: 1.0\r\n";
  return @mail($to, $subject, $body, $headers);
}
function generate_reset_token(PDO $db, int $userId): string {
  $token = bin2hex(random_bytes(32));
  $db->prepare('DELETE FROM password_resets WHERE user_id=?')->execute([$userId]);
  $db->prepare('INSERT INTO password_resets(token,user_id,expires_at) VALUES(?,?,?)')
     ->execute([$token, $userId, time() + 3600]);
  return $token;
}
function consume_reset_token(PDO $db, string $token): ?int {
  $st = $db->prepare('SELECT user_id FROM password_resets WHERE token=? AND expires_at>? AND used=0');
  $st->execute([$token, time()]);
  $row = $st->fetch();
  if (!$row) return null;
  $db->prepare('UPDATE password_resets SET used=1 WHERE token=?')->execute([$token]);
  return (int)$row['user_id'];
}
PHP

  chown -R root:root "$APP_DIR/app"; chmod -R 0755 "$APP_DIR/app"
  ok "app/"
}

write_views() {
  cat > "$APP_DIR/views/layout.php" <<'PHP'
<?php /* @var string $content @var string $title */
$u = auth_user();
$appName = $GLOBALS['__app_name'] ?? 'LiteForum';
$appTagline = $GLOBALS['__app_tagline'] ?? '';
$flash = flash_get();
$unread = $u ? notif_unread_count($GLOBALS['db'],(int)$u['id']) : 0;
$online = online_count($GLOBALS['db']);
?>
<!doctype html>
<html lang="<?= e($_SESSION['ui_lang'] ?? 'tr') ?>" dir="<?= ($_SESSION['ui_lang'] ?? 'tr')==='ar'?'rtl':'ltr' ?>">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= e($title ?? $appName) ?> · <?= e($appName) ?></title>
<style nonce="<?= e(csp_nonce()) ?>">
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
  .glass{background:var(--panel);backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);border:1px solid var(--border);border-radius:1rem;box-shadow:0 25px 50px -12px rgba(0,0,0,.4);transition:transform .2s ease,border-color .2s,box-shadow .2s}
  .glass:hover{border-color:color-mix(in srgb,var(--accent-500) 30%,var(--border));box-shadow:0 25px 50px -12px var(--glow)}
  .card{padding:1.75rem}
  header.nav{position:sticky;top:0;z-index:50;border-bottom:1px solid var(--border);background:color-mix(in srgb,var(--bg) 80%,transparent);backdrop-filter:blur(16px);-webkit-backdrop-filter:blur(16px)}
  header.nav .inner{max-width:1160px;margin:0 auto;padding:.9rem 1.25rem;display:flex;justify-content:space-between;align-items:center;gap:.75rem;flex-wrap:wrap}
  .logo{display:flex;gap:.6rem;align-items:center;color:var(--fg);font-weight:700;font-size:1.1rem;letter-spacing:-.02em}
  .logo .mark{width:34px;height:34px;border-radius:.6rem;background:linear-gradient(135deg,var(--accent-500),var(--accent-600));display:flex;align-items:center;justify-content:center;font-weight:800;color:#fff;font-size:1rem;box-shadow:0 4px 12px var(--glow)}
  nav.actions{display:flex;gap:.5rem;align-items:center;flex-wrap:wrap}
  nav.actions a,nav.actions button{padding:.45rem .75rem;border-radius:.55rem;font-size:.9rem;transition:all .15s}
  nav.actions a:hover{background:var(--panel2);color:var(--fg);text-decoration:none}
  nav.actions .icon-link{position:relative;padding:.45rem .55rem}
  .badge-notif{position:absolute;top:-2px;right:-2px;background:#ef4444;color:#fff;border-radius:999px;font-size:10px;font-weight:700;min-width:16px;height:16px;display:flex;align-items:center;justify-content:center;padding:0 4px;box-shadow:0 0 0 2px var(--bg)}
  input,textarea,select{background:var(--bg2);color:var(--fg);border:1px solid var(--border);border-radius:.55rem;padding:.65rem .85rem;width:100%;font:inherit;font-size:.95rem;transition:border-color .15s,box-shadow .15s}
  input:focus,textarea:focus,select:focus{outline:none;border-color:var(--accent-500);box-shadow:0 0 0 3px var(--glow)}
  textarea{resize:vertical;min-height:100px;font-family:inherit}
  button,.btn{background:linear-gradient(135deg,var(--accent-500),var(--accent-600));color:#fff;border:0;border-radius:.55rem;padding:.65rem 1.1rem;cursor:pointer;font-weight:600;font-size:.95rem;transition:transform .1s,filter .15s,box-shadow .2s;position:relative;display:inline-flex;align-items:center;gap:.4rem}
  button:hover,.btn:hover{filter:brightness(1.1);box-shadow:0 8px 20px -4px var(--glow);text-decoration:none;color:#fff}
  button:active,.btn:active{transform:translateY(1px)}
  button:disabled{opacity:.5;cursor:not-allowed;filter:none}
  .btn-ghost{background:transparent;border:1px solid var(--border);color:var(--fg)}
  .btn-ghost:hover{background:var(--panel2);filter:none;box-shadow:none;color:var(--fg)}
  .btn-sm{padding:.4rem .8rem;font-size:.85rem}
  .btn-danger{background:linear-gradient(135deg,#ef4444,#dc2626)}
  .btn-danger:hover{box-shadow:0 8px 20px -4px rgba(239,68,68,.4)}
  .muted{color:var(--fg-muted)}
  .text-sm{font-size:.875rem}
  .text-xs{font-size:.75rem}
  .grid{display:grid;gap:1rem}
  .flex{display:flex;gap:.75rem;align-items:center}
  .flex-wrap{flex-wrap:wrap}
  .flex-col{flex-direction:column}
  .space-y>*+*{margin-top:1rem}
  table{width:100%;border-collapse:collapse}
  th,td{text-align:left;padding:.85rem 1rem;border-bottom:1px solid var(--border)}
  th{font-size:.78rem;text-transform:uppercase;letter-spacing:.05em;color:var(--fg-muted);font-weight:600}
  tr:hover{background:var(--panel2)}
  code{background:var(--bg2);padding:1px 6px;border-radius:4px;color:var(--accent-400);font-size:.9em;font-family:ui-monospace,monospace}
  mark{background:var(--accent-500);color:#fff;padding:1px 4px;border-radius:3px}
  .flash{padding:.85rem 1.1rem;border-radius:.75rem;margin-bottom:1rem;display:flex;align-items:center;gap:.6rem;animation:slideDown .3s ease;font-size:.9rem}
  .flash-ok{background:rgba(16,185,129,.12);border:1px solid rgba(16,185,129,.35);color:#34d399}
  .flash-err{background:rgba(239,68,68,.12);border:1px solid rgba(239,68,68,.35);color:#fca5a5}
  .flash-info{background:rgba(99,102,241,.12);border:1px solid rgba(99,102,241,.35);color:#a5b4fc}
  .hero{padding:3rem 1rem;text-align:center;position:relative;animation:fadeIn .4s ease}
  .hero h1{font-size:2.5rem;margin:0 0 .75rem;font-weight:800;letter-spacing:-.03em;background:linear-gradient(135deg,var(--fg),var(--accent-400));-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent}
  .hero p{color:var(--fg-muted);font-size:1.05rem;margin:0;max-width:600px;margin:0 auto}
  .stat-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:1rem;margin-bottom:1.5rem}
  .stat-card{text-align:center;padding:1.25rem;background:var(--panel);border:1px solid var(--border);border-radius:.85rem;transition:transform .2s,border-color .2s}
  .stat-card:hover{transform:translateY(-2px);border-color:var(--accent-500)}
  .stat-card .num{font-size:1.75rem;font-weight:800;color:var(--accent-400);line-height:1;letter-spacing:-.02em}
  .stat-card .label{font-size:.75rem;text-transform:uppercase;letter-spacing:.05em;color:var(--fg-muted);margin-top:.35rem;font-weight:600}
  .category-card{display:flex;gap:1rem;align-items:center;padding:1.1rem 1.25rem;background:var(--panel);border:1px solid var(--border);border-radius:.85rem;transition:transform .2s,border-color .2s,background .2s;animation:fadeIn .3s ease}
  .category-card:hover{transform:translateX(4px);border-color:var(--accent-500);background:var(--panel2)}
  .category-card .icon{font-size:2rem;width:52px;height:52px;display:flex;align-items:center;justify-content:center;background:var(--panel2);border-radius:.75rem;border:1px solid var(--border);flex-shrink:0}
  .category-card .info{flex:1;min-width:0}
  .category-card .info h3{margin:0 0 .25rem;font-size:1.05rem;color:var(--fg)}
  .category-card .info p{margin:0;color:var(--fg-muted);font-size:.85rem}
  .category-card .count{text-align:center;color:var(--fg-muted);font-size:.75rem;text-transform:uppercase;letter-spacing:.05em;min-width:60px}
  .category-card .count strong{display:block;color:var(--accent-400);font-size:1.4rem;font-weight:800}
  .topic-row{display:flex;gap:.85rem;align-items:flex-start;padding:1rem 1.15rem;border-bottom:1px solid var(--border);transition:background .15s}
  .topic-row:hover{background:var(--panel2)}
  .topic-row .info{flex:1;min-width:0}
  .topic-row .info .title{font-weight:600;color:var(--fg);font-size:1rem;display:inline-flex;align-items:center;gap:.4rem;flex-wrap:wrap}
  .topic-row .info .meta{color:var(--fg-muted);font-size:.82rem;margin-top:.25rem;display:flex;gap:.75rem;flex-wrap:wrap}
  .topic-row .counts{display:flex;gap:1rem;text-align:center;flex-shrink:0}
  .topic-row .counts .c{font-size:.85rem;color:var(--fg-muted)}
  .topic-row .counts .c strong{display:block;color:var(--fg);font-weight:700}
  .pill{display:inline-block;padding:.15rem .55rem;border-radius:999px;background:var(--panel2);border:1px solid var(--border);font-size:.72rem;color:var(--fg-muted);font-weight:600;text-transform:uppercase;letter-spacing:.04em}
  .pill-accent{background:var(--glow);border-color:var(--accent-500);color:var(--accent-400)}
  .pill-danger{background:rgba(239,68,68,.15);border-color:#ef4444;color:#fca5a5}
  .post-card{padding:1.25rem 1.5rem;background:var(--panel);border:1px solid var(--border);border-radius:.85rem;margin-bottom:.85rem;transition:border-color .2s;animation:fadeIn .3s ease}
  .post-card:hover{border-color:color-mix(in srgb,var(--accent-500) 30%,var(--border))}
  .post-card .head{display:flex;gap:.75rem;align-items:center;margin-bottom:.85rem;font-size:.85rem}
  .post-card .head .author{font-weight:600;color:var(--fg)}
  .post-card .head .time{color:var(--fg-muted)}
  .post-card .body{color:var(--fg);line-height:1.65;word-wrap:break-word;overflow-wrap:break-word}
  .post-card .body blockquote{margin:.5rem 0}
  .post-card .reactions{display:flex;gap:.4rem;margin-top:.75rem;flex-wrap:wrap}
  .react-btn{background:transparent;border:1px solid var(--border);border-radius:.55rem;padding:.3rem .6rem;cursor:pointer;color:var(--fg);font-size:.85rem;transition:all .15s;display:inline-flex;align-items:center;gap:.25rem}
  .react-btn:hover{background:var(--panel2);border-color:var(--accent-500);transform:scale(1.05)}
  .react-btn.active{background:var(--glow);border-color:var(--accent-500);color:var(--accent-400)}
  .breadcrumb{display:flex;gap:.5rem;align-items:center;font-size:.85rem;color:var(--fg-muted);margin-bottom:1rem;flex-wrap:wrap}
  .breadcrumb a{color:var(--accent-400)}
  .avatar-lg{width:96px;height:96px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:2.5rem;font-weight:800;color:#fff;box-shadow:0 12px 24px var(--glow)}
  .footer{padding:3rem 1.25rem 2rem;text-align:center;color:var(--fg-muted);font-size:.85rem;border-top:1px solid var(--border);margin-top:3rem}
  .footer a{color:var(--accent-400)}
  .online-dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:#10b981;box-shadow:0 0 8px #10b981;margin-right:.4rem;animation:pulse 2s infinite}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.5}}
  .mod-bar{display:flex;gap:.4rem;flex-wrap:wrap;margin-top:.85rem;padding-top:.85rem;border-top:1px dashed var(--border)}
  .mod-bar form{margin:0;display:inline}
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
  <a class="logo" href="/"><span class="mark"><?= e(mb_substr($appName,0,1)) ?></span><span><?= e($appName) ?></span></a>
  <nav class="actions">
    <a href="/activity.php" title="<?= e(t('activity')) ?>">📊</a>
    <a href="/stats.php" title="<?= e(t('stats')) ?>">📈</a>
    <form action="/search.php" method="get" style="margin:0">
      <input name="q" placeholder="<?= e(t('search_placeholder')) ?>" style="width:150px;padding:.4rem .65rem;font-size:.85rem">
    </form>
    <form method="post" action="/lang.php" style="margin:0">
      <?= csrf_field() ?>
      <select name="lang" onchange="this.form.submit()" style="width:auto;padding:.35rem .55rem;font-size:.8rem">
        <?php foreach (($GLOBALS['__config']['available_langs'] ?? ['tr','en']) as $lc): ?>
          <option value="<?= e($lc) ?>" <?= ($_SESSION['ui_lang']??'')===$lc?'selected':'' ?>><?= e(strtoupper($lc)) ?></option>
        <?php endforeach; ?>
      </select>
    </form>
    <?php if ($u): ?>
      <a href="/notifications.php" class="icon-link" title="<?= e(t('notifications')) ?>">🔔<?php if ($unread>0): ?><span class="badge-notif"><?= $unread ?></span><?php endif; ?></a>
      <a href="/user.php?u=<?= e($u['username']) ?>" class="flex" style="gap:.4rem">
        <?= user_avatar($u['username'], $u['avatar_color'] ?? '#6366f1', 28) ?>
        <span style="font-size:.88rem;font-weight:600">@<?= e($u['username']) ?></span>
      </a>
      <?php if (is_mod($u)): ?><a href="/admin.php" class="icon-link" title="Admin">⚙</a><?php endif; ?>
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
    <span><?= $flash['type']==='ok' ? '✅' : ($flash['type']==='err' ? '❌' : 'ℹ️') ?></span>
    <span><?= e($flash['msg']) ?></span>
  </div>
<?php endif; ?>
<?= $content ?>
</main>
<footer class="footer">
  <p><strong><?= e($appName) ?></strong> <?= e($appTagline) ?></p>
  <p style="margin-top:.5rem"><span class="online-dot"></span><?= $online ?> <?= e(t('online_users')) ?></p>
</footer>
</body></html>
PHP

  cat > "$APP_DIR/views/home.php" <<'PHP'
<?php /* @var array $cats @var array $recent @var array $stats */ $lc = $_SESSION['ui_lang'] ?? 'tr'; ?>
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

<h2 style="margin:1.5rem 0 1rem;font-size:1.25rem;letter-spacing:-.01em"><?= e(t('categories')) ?></h2>
<div class="grid" style="margin-bottom:2rem">
  <?php foreach ($cats as $c): ?>
    <a href="/category.php?slug=<?= e($c['slug']) ?>" class="category-card">
      <span class="icon"><?= e($c['icon'] ?? '💬') ?></span>
      <div class="info">
        <h3><?= e(cat_name($c, $lc)) ?></h3>
        <?php $desc = cat_desc($c, $lc); if ($desc): ?><p><?= e($desc) ?></p><?php endif; ?>
      </div>
      <div class="count">
        <strong><?= (int)$c['n'] ?></strong>
        <?= e(t('topics')) ?>
      </div>
    </a>
  <?php endforeach; ?>
</div>

<h2 style="margin:1.5rem 0 1rem;font-size:1.25rem;letter-spacing:-.01em"><?= e(t('recent_topics')) ?></h2>
<div class="glass">
  <?php if (empty($recent)): ?>
    <div class="card muted" style="text-align:center"><?= e(t('no_topics_yet')) ?></div>
  <?php else: foreach ($recent as $r): ?>
    <a href="/topic.php?id=<?= (int)$r['id'] ?>" class="topic-row" style="text-decoration:none;color:inherit">
      <?= user_avatar($r['username'], '#6366f1', 36) ?>
      <div class="info">
        <div class="title"><?php if ((int)$r['is_pinned']): ?><span class="pill pill-accent">📌</span><?php endif; ?> <?= e($r['title']) ?></div>
        <div class="meta">
          <span>@<?= e($r['username']) ?></span>
          <span>· <?= e($r['cat_slug']) ?></span>
          <span>· <?= time_ago((int)$r['updated_at']) ?></span>
        </div>
      </div>
      <div class="counts">
        <div class="c"><strong><?= (int)$r['post_count'] ?></strong><?= e(t('posts')) ?></div>
      </div>
    </a>
  <?php endforeach; endif; ?>
</div>
PHP

  cat > "$APP_DIR/views/category.php" <<'PHP'
<?php /* @var array $cat @var array $topics @var int $page @var int $total */ $lc = $_SESSION['ui_lang'] ?? 'tr'; ?>
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

<div class="glass">
  <?php if (empty($topics)): ?>
    <div class="card muted" style="text-align:center"><?= e(t('no_topics_yet')) ?></div>
  <?php else: foreach ($topics as $t): ?>
    <a href="/topic.php?id=<?= (int)$t['id'] ?>" class="topic-row" style="text-decoration:none;color:inherit">
      <?= user_avatar($t['username'], $t['avatar_color'] ?? '#6366f1', 36) ?>
      <div class="info">
        <div class="title">
          <?php if ((int)$t['is_pinned']): ?><span class="pill pill-accent">📌</span><?php endif; ?>
          <?php if ((int)$t['is_locked']): ?><span class="pill">🔒</span><?php endif; ?>
          <?= e($t['title']) ?>
        </div>
        <div class="meta">
          <span>@<?= e($t['username']) ?></span>
          <span>· <?= time_ago((int)$t['updated_at']) ?></span>
          <span>· <?= (int)$t['views'] ?> <?= e(t('views')) ?></span>
        </div>
      </div>
      <div class="counts">
        <div class="c"><strong><?= (int)$t['post_count'] ?></strong><?= e(t('posts')) ?></div>
      </div>
    </a>
  <?php endforeach; endif; ?>
</div>
<?php if (($total ?? 0) > 25): ?>
  <div class="flex" style="justify-content:center;margin-top:1.5rem;gap:.5rem">
    <?php $totalPages = (int)ceil($total / 25);
    for ($i=1; $i<=$totalPages; $i++): ?>
      <a href="?slug=<?= e($cat['slug']) ?>&page=<?= $i ?>" class="<?= $i===$page?'btn':'btn-ghost btn' ?>" style="padding:.4rem .8rem;font-size:.85rem"><?= $i ?></a>
    <?php endfor; ?>
  </div>
<?php endif; ?>
PHP

  cat > "$APP_DIR/views/topic.php" <<'PHP'
<?php /* @var array $topic @var array $posts @var bool $watching @var array $reactions */ $u = auth_user(); ?>
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
  <div class="flex muted" style="font-size:.85rem;flex-wrap:wrap">
    <?= user_avatar($topic['username'], '#6366f1', 24) ?>
    <span>@<?= e($topic['username']) ?></span>
    <span>· <?= date('Y-m-d H:i', (int)$topic['created_at']) ?></span>
    <span>· <?= (int)$topic['views'] ?> <?= e(t('views')) ?></span>
  </div>
  <div class="flex" style="margin-top:.85rem;flex-wrap:wrap">
  <?php if ($u): ?>
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
        <form method="post" action="/mod.php" style="margin:0" onsubmit="return confirm('<?= e(t('delete_confirm')) ?>')">
          <?= csrf_field() ?>
          <input type="hidden" name="action" value="delete_topic">
          <input type="hidden" name="topic_id" value="<?= (int)$topic['id'] ?>">
          <button class="btn-danger btn btn-sm" type="submit">🗑 <?= e(t('delete_topic')) ?></button>
        </form>
      <?php endif; ?>
    <?php endif; ?>
  <?php endif; ?>
  </div>
</div>

<?php foreach ($posts as $p):
  $pid = (int)$p['id'];
  $postReacts = $reactions[$pid] ?? [];
  $myReacts = $myReacted[$pid] ?? [];
?>
  <div class="post-card" style="<?= (int)$p['is_deleted']?'opacity:.5':'' ?>">
    <div class="head">
      <?= user_avatar($p['username'], $p['avatar_color'] ?? '#6366f1', 28) ?>
      <span class="author">@<?= e($p['username']) ?></span>
      <span class="time">· <?= time_ago((int)$p['created_at']) ?></span>
      <?php if (!empty($p['edited_at'])): ?><span class="time">· <?= e(t('edited')) ?></span><?php endif; ?>
    </div>
    <div class="body"><?= (int)$p['is_deleted'] ? '<em class="muted">'.e(t('deleted_post')).'</em>' : render_post($p['body']) ?></div>
    <?php if (!$u || (int)$p['is_deleted']): ?>
      <?php if (!empty($postReacts)): ?>
        <div class="reactions">
          <?php foreach ($postReacts as $emoji => $cnt): if ($cnt>0): ?>
            <span class="react-btn"><?= e($emoji) ?> <?= (int)$cnt ?></span>
          <?php endif; endforeach; ?>
        </div>
      <?php endif; ?>
    <?php else: ?>
      <div class="reactions">
        <?php foreach (['👍','❤️','🔥','😂','😮'] as $emoji):
          $cnt = $postReacts[$emoji] ?? 0;
          $active = in_array($emoji, $myReacts);
        ?>
          <form method="post" action="/react.php" style="margin:0;display:inline">
            <?= csrf_field() ?>
            <input type="hidden" name="post_id" value="<?= $pid ?>">
            <input type="hidden" name="emoji" value="<?= e($emoji) ?>">
            <input type="hidden" name="back" value="/topic.php?id=<?= (int)$topic['id'] ?>">
            <button class="react-btn <?= $active?'active':'' ?>" type="submit"><?= e($emoji) ?><?php if ($cnt>0): ?> <?= $cnt ?><?php endif; ?></button>
          </form>
        <?php endforeach; ?>
      </div>
    <?php endif; ?>
    <?php if (is_mod($u) && !(int)$p['is_deleted']): ?>
      <div class="mod-bar">
        <?php if (is_admin($u) || (int)$p['user_id'] === (int)$u['id']): ?>
          <form method="post" action="/mod.php" style="margin:0" onsubmit="return confirm('<?= e(t('delete_confirm')) ?>')">
            <?= csrf_field() ?>
            <input type="hidden" name="action" value="delete_post">
            <input type="hidden" name="post_id" value="<?= $pid ?>">
            <input type="hidden" name="topic_id" value="<?= (int)$topic['id'] ?>">
            <button class="btn-ghost btn btn-sm" type="submit">🗑 <?= e(t('delete_post')) ?></button>
          </form>
        <?php endif; ?>
      </div>
    <?php endif; ?>
  </div>
<?php endforeach; ?>

<?php if ($u && empty($topic['is_locked'])): ?>
<div class="glass card" style="margin-top:1.5rem">
  <h2 style="margin:0 0 1rem;font-size:1.15rem"><?= e(t('reply')) ?></h2>
  <form method="post" action="/topic.php?id=<?= (int)$topic['id'] ?>" class="grid">
    <?= csrf_field() ?><input type="hidden" name="action" value="reply">
    <textarea name="body" rows="6" required placeholder="**bold** *italic* `code` [link](url) @user &gt; quote"></textarea>
    <button type="submit"><?= e(t('submit')) ?></button>
  </form>
</div>
<?php elseif (empty($topic['is_locked'])): ?>
<div class="glass card" style="margin-top:1.5rem;text-align:center">
  <a href="/login.php"><?= e(t('login')) ?></a> — <?= e(t('reply')) ?>
</div>
<?php endif; ?>
PHP

  cat > "$APP_DIR/views/new-topic.php" <<'PHP'
<?php /* @var array $cat @var string $error */ $lc = $_SESSION['ui_lang'] ?? 'tr'; ?>
<div class="breadcrumb">
  <a href="/"><?= e(t('home')) ?></a> <span>›</span>
  <a href="/category.php?slug=<?= e($cat['slug']) ?>"><?= e(cat_name($cat, $lc)) ?></a> <span>›</span>
  <span><?= e(t('new_topic')) ?></span>
</div>
<div class="glass card" style="max-width:720px;margin:0 auto">
  <h1 style="margin:0 0 1.25rem;font-size:1.5rem"><?= e(t('new_topic')) ?></h1>
  <?php if (!empty($error)): ?><div class="flash flash-err"><?= e($error) ?></div><?php endif; ?>
  <form method="post" class="grid">
    <?= csrf_field() ?>
    <input name="title" required minlength="3" maxlength="200" placeholder="<?= e(t('title')) ?>">
    <textarea name="body" rows="10" required placeholder="<?= e(t('body')) ?>"></textarea>
    <button type="submit"><?= e(t('submit')) ?></button>
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
  <div style="margin-top:1.5rem;padding-top:1.5rem;border-top:1px solid var(--border);text-align:center">
    <a href="<?= e($url) ?>"><img src="<?= e($config['erendev']['button_svg']) ?>" alt="ErenDev ile Giriş Yap" width="240" height="48" style="height:48px;transition:transform .15s" onmouseover="this.style.transform='scale(1.03)'" onmouseout="this.style.transform='scale(1)'"></a>
  </div>
  <?php endif; ?>
  <p class="muted text-sm" style="margin-top:1.25rem;text-align:center;display:flex;justify-content:space-between">
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
    <input name="password" type="password" required minlength="10" placeholder="<?= e(t('password')) ?> (min 10)">
    <input name="hp" type="text" tabindex="-1" style="display:none">
    <button type="submit"><?= e(t('register')) ?></button>
  </form>
  <?php $showErenDev = (($config['default_lang'] ?? '') === 'tr') && (($_SESSION['ui_lang'] ?? '') === 'tr');
  if ($showErenDev): ?>
    <div style="margin-top:1.5rem;padding-top:1.5rem;border-top:1px solid var(--border);text-align:center">
      <a href="/login.php"><img src="<?= e($config['erendev']['button_svg']) ?>" alt="ErenDev ile Giriş Yap" style="height:48px"></a>
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
      <button type="submit"><?= e(t('reset_password')) ?></button>
    </form>
  <?php endif; ?>
  <p class="muted text-sm" style="margin-top:1.25rem;text-align:center">
    <a href="/login.php">← <?= e(t('login')) ?></a>
  </p>
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
    <button type="submit"><?= e(t('reset_password')) ?></button>
  </form>
</div>
PHP

  cat > "$APP_DIR/views/search.php" <<'PHP'
<?php /* @var string $q @var array $result @var array $cats */ $lc = $_SESSION['ui_lang'] ?? 'tr'; ?>
<div class="glass card" style="margin-bottom:1rem">
  <h1 style="margin:0 0 1rem;font-size:1.5rem"><?= e(t('search')) ?></h1>
  <form method="get" action="/search.php" class="flex flex-wrap" style="gap:.5rem">
    <input name="q" value="<?= e($q) ?>" placeholder="<?= e(t('search_placeholder')) ?>" style="flex:1;min-width:200px">
    <select name="cat" style="width:auto;max-width:180px">
      <option value="">— <?= e(t('categories')) ?> —</option>
      <?php foreach ($cats as $c): ?>
        <option value="<?= (int)$c['id'] ?>" <?= (($_GET['cat']??'')==$c['id'])?'selected':'' ?>><?= e(cat_name($c, $lc)) ?></option>
      <?php endforeach; ?>
    </select>
    <input name="author" placeholder="author" value="<?= e($_GET['author']??'') ?>" style="width:120px">
    <button type="submit"><?= e(t('search')) ?></button>
  </form>
</div>
<?php if ($q !== ''): ?>
<div class="glass">
  <?php if (empty($result['rows'])): ?>
    <div class="card muted" style="text-align:center"><?= e(t('no_results')) ?></div>
  <?php else: ?>
    <div class="card" style="padding-bottom:0"><strong><?= (int)$result['total'] ?> results</strong></div>
    <?php foreach ($result['rows'] as $r): ?>
      <div class="topic-row" style="display:block">
        <a href="/topic.php?id=<?= (int)$r['topic_id'] ?>" style="font-weight:600;font-size:1rem"><?= e($r['topic_title']) ?></a>
        <div class="meta" style="margin-top:.35rem;color:var(--fg-muted);font-size:.82rem">@<?= e($r['username']) ?></div>
        <p style="margin:.5rem 0 0;color:var(--fg)"><?= $r['snippet'] ?></p>
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
  <?php if (empty($items)): ?><div class="card muted" style="text-align:center"><?= e(t('no_notifications')) ?></div>
  <?php else: foreach ($items as $n): ?>
    <div class="topic-row" style="opacity:<?= $n['read_at']?'0.6':'1' ?>">
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
    <label class="text-sm">
      <span class="muted" style="display:block;margin-bottom:.35rem"><?= e(t('bio')) ?></span>
      <textarea name="bio" rows="3" maxlength="500" placeholder="..."><?= e($user['bio'] ?? '') ?></textarea>
    </label>
    <label class="text-sm">
      <span class="muted" style="display:block;margin-bottom:.35rem"><?= e(t('theme')) ?></span>
      <select name="theme">
        <?php foreach (($GLOBALS['__config']['themes']??['dark']) as $th): ?>
          <option value="<?= e($th) ?>" <?= ($user['theme']??'dark')===$th?'selected':'' ?>><?= e($th) ?></option>
        <?php endforeach; ?>
      </select>
    </label>
    <label class="text-sm">
      <span class="muted" style="display:block;margin-bottom:.35rem"><?= e(t('accent')) ?></span>
      <select name="accent">
        <?php foreach (($GLOBALS['__config']['accents']??['indigo']) as $ac): ?>
          <option value="<?= e($ac) ?>" <?= ($user['accent']??'indigo')===$ac?'selected':'' ?>><?= e($ac) ?></option>
        <?php endforeach; ?>
      </select>
    </label>
    <label class="text-sm">
      <span class="muted" style="display:block;margin-bottom:.35rem">Avatar color</span>
      <input type="color" name="avatar_color" value="<?= e($user['avatar_color'] ?? '#6366f1') ?>" style="height:44px;padding:4px">
    </label>
    <label class="flex"><input type="checkbox" name="notify_mentions" style="width:auto" <?= ($user['notify_mentions']??1)?'checked':'' ?>> <span>Mentions</span></label>
    <label class="flex"><input type="checkbox" name="notify_replies" style="width:auto" <?= ($user['notify_replies']??1)?'checked':'' ?>> <span>Replies</span></label>
    <label class="flex"><input type="checkbox" name="notify_reactions" style="width:auto" <?= ($user['notify_reactions']??1)?'checked':'' ?>> <span>Reactions</span></label>
    <label class="flex"><input type="checkbox" name="notify_digest" style="width:auto" <?= ($user['notify_digest']??0)?'checked':'' ?>> <span>Digest</span></label>
    <button type="submit"><?= e(t('save')) ?></button>
  </form>
</div>

<div class="glass card" style="max-width:560px;margin:1rem auto">
  <h2 style="margin:0 0 1.25rem;font-size:1.15rem"><?= e(t('password_change')) ?></h2>
  <form method="post" action="/settings.php" class="grid">
    <?= csrf_field() ?>
    <input type="hidden" name="action" value="password">
    <input name="current_password" type="password" required placeholder="<?= e(t('current_password')) ?>">
    <input name="new_password" type="password" required minlength="10" placeholder="<?= e(t('new_password')) ?>">
    <input name="confirm_password" type="password" required minlength="10" placeholder="<?= e(t('confirm_password')) ?>">
    <button type="submit"><?= e(t('password_change')) ?></button>
  </form>
</div>
PHP

  cat > "$APP_DIR/views/user.php" <<'PHP'
<?php /* @var array $profile @var array $topics @var array $posts */ $me = auth_user(); ?>
<div class="glass card" style="margin-bottom:1.25rem;display:flex;gap:1.5rem;align-items:center;flex-wrap:wrap">
  <div class="avatar-lg" style="background:linear-gradient(135deg,<?= e($profile['avatar_color']) ?>,<?= e($profile['avatar_color']) ?>99)"><?= e(mb_strtoupper(mb_substr($profile['username'],0,1))) ?></div>
  <div style="flex:1;min-width:200px">
    <h1 style="margin:0 0 .35rem;font-size:1.75rem">@<?= e($profile['username']) ?></h1>
    <?php if ($profile['bio']): ?><p class="muted" style="margin:0 0 .5rem"><?= e($profile['bio']) ?></p><?php endif; ?>
    <div class="flex flex-wrap muted" style="font-size:.85rem;gap:1rem">
      <span><span class="pill"><?= e($profile['role']) ?></span></span>
      <?php if ((int)$profile['banned']): ?><span class="pill pill-danger"><?= e(t('banned')) ?></span><?php endif; ?>
      <span><?= e(t('joined')) ?>: <?= date('Y-m-d', (int)$profile['created_at']) ?></span>
      <span><?= e(t('last_seen')) ?>: <?= time_ago((int)($profile['last_seen_at'] ?? $profile['created_at'])) ?></span>
    </div>
  </div>
  <?php if (is_admin($me) && (int)$profile['id'] !== (int)$me['id']): ?>
    <div class="flex flex-col" style="gap:.4rem">
      <?php if (!(int)$profile['banned']): ?>
        <form method="post" action="/mod.php" style="margin:0" onsubmit="return confirm('<?= e(t('delete_confirm')) ?>')">
          <?= csrf_field() ?>
          <input type="hidden" name="action" value="ban_user">
          <input type="hidden" name="user_id" value="<?= (int)$profile['id'] ?>">
          <input type="hidden" name="state" value="1">
          <button class="btn-danger btn btn-sm" type="submit">🚫 <?= e(t('ban_user')) ?></button>
        </form>
      <?php else: ?>
        <form method="post" action="/mod.php" style="margin:0">
          <?= csrf_field() ?>
          <input type="hidden" name="action" value="ban_user">
          <input type="hidden" name="user_id" value="<?= (int)$profile['id'] ?>">
          <input type="hidden" name="state" value="0">
          <button class="btn-ghost btn btn-sm" type="submit"><?= e(t('unban_user')) ?></button>
        </form>
      <?php endif; ?>
    </div>
  <?php endif; ?>
</div>

<h2 style="margin:1.5rem 0 1rem;font-size:1.15rem"><?= e(t('topics')) ?> (<?= count($topics) ?>)</h2>
<div class="glass">
  <?php if (empty($topics)): ?><div class="card muted" style="text-align:center">—</div>
  <?php else: foreach ($topics as $t): ?>
    <a href="/topic.php?id=<?= (int)$t['id'] ?>" class="topic-row" style="text-decoration:none;color:inherit;display:block">
      <div class="title"><?= e($t['title']) ?></div>
      <div class="meta"><span><?= e($t['cat_name']) ?></span><span>· <?= time_ago((int)$t['updated_at']) ?></span></div>
    </a>
  <?php endforeach; endif; ?>
</div>

<h2 style="margin:1.5rem 0 1rem;font-size:1.15rem"><?= e(t('posts')) ?> (<?= count($posts) ?>)</h2>
<div class="glass">
  <?php if (empty($posts)): ?><div class="card muted" style="text-align:center">—</div>
  <?php else: foreach ($posts as $p): ?>
    <a href="/topic.php?id=<?= (int)$p['topic_id'] ?>" class="topic-row" style="text-decoration:none;color:inherit;display:block">
      <div class="title"><?= e($p['topic_title']) ?></div>
      <div class="meta"><span><?= time_ago((int)$p['created_at']) ?></span></div>
      <p style="margin:.5rem 0 0;color:var(--fg-muted);font-size:.9rem"><?= e(mb_substr($p['body'], 0, 140)) ?><?= mb_strlen($p['body']) > 140 ? '…' : '' ?></p>
    </a>
  <?php endforeach; endif; ?>
</div>
PHP

  cat > "$APP_DIR/views/stats.php" <<'PHP'
<?php /* @var array $stats @var array $topUsers */ ?>
<div class="hero" style="padding:1.5rem 1rem">
  <h1 style="font-size:2rem"><?= e(t('stats')) ?></h1>
</div>
<div class="stat-grid">
  <div class="stat-card"><div class="num"><?= (int)$stats['topics'] ?></div><div class="label"><?= e(t('total_topics')) ?></div></div>
  <div class="stat-card"><div class="num"><?= (int)$stats['posts'] ?></div><div class="label"><?= e(t('total_posts')) ?></div></div>
  <div class="stat-card"><div class="num"><?= (int)$stats['users'] ?></div><div class="label"><?= e(t('total_users')) ?></div></div>
  <div class="stat-card"><div class="num"><?= (int)$stats['online'] ?></div><div class="label"><?= e(t('online_users')) ?></div></div>
</div>
<?php if ($stats['newest']): ?>
<div class="glass card" style="margin-bottom:1rem">
  <strong><?= e(t('members')) ?>:</strong> <a href="/user.php?u=<?= e($stats['newest']['username']) ?>">@<?= e($stats['newest']['username']) ?></a>
  <span class="muted" style="margin-left:.5rem">· <?= time_ago((int)$stats['newest']['created_at']) ?></span>
</div>
<?php endif; ?>
<h2 style="margin:1.5rem 0 1rem;font-size:1.15rem"><?= e(t('popular')) ?></h2>
<div class="glass">
  <?php foreach ($topUsers as $tu): ?>
    <a href="/user.php?u=<?= e($tu['username']) ?>" class="topic-row" style="text-decoration:none;color:inherit">
      <?= user_avatar($tu['username'], $tu['avatar_color'] ?? '#6366f1', 32) ?>
      <div class="info"><div class="title">@<?= e($tu['username']) ?></div></div>
      <div class="counts"><div class="c"><strong><?= (int)$tu['cnt'] ?></strong><?= e(t('posts')) ?></div></div>
    </a>
  <?php endforeach; ?>
</div>
PHP

  cat > "$APP_DIR/views/activity.php" <<'PHP'
<?php /* @var array $topics @var array $posts */ ?>
<div class="hero" style="padding:1.5rem 1rem">
  <h1 style="font-size:2rem"><?= e(t('activity')) ?></h1>
</div>
<h2 style="margin:1.5rem 0 1rem;font-size:1.15rem"><?= e(t('recent_topics')) ?></h2>
<div class="glass" style="margin-bottom:1.5rem">
  <?php foreach ($topics as $t): ?>
    <a href="/topic.php?id=<?= (int)$t['id'] ?>" class="topic-row" style="text-decoration:none;color:inherit">
      <?= user_avatar($t['username'], '#6366f1', 32) ?>
      <div class="info">
        <div class="title"><?= e($t['title']) ?></div>
        <div class="meta"><span>@<?= e($t['username']) ?></span><span>· <?= time_ago((int)$t['updated_at']) ?></span></div>
      </div>
    </a>
  <?php endforeach; ?>
</div>
<h2 style="margin:1.5rem 0 1rem;font-size:1.15rem"><?= e(t('latest_posts')) ?></h2>
<div class="glass">
  <?php foreach ($posts as $p): ?>
    <a href="/topic.php?id=<?= (int)$p['topic_id'] ?>" class="topic-row" style="text-decoration:none;color:inherit;display:block">
      <?= user_avatar($p['username'], '#6366f1', 32) ?>
      <div class="info">
        <div class="title"><?= e($p['topic_title']) ?></div>
        <div class="meta"><span>@<?= e($p['username']) ?></span><span>· <?= time_ago((int)$p['created_at']) ?></span></div>
        <p style="margin:.5rem 0 0;color:var(--fg-muted);font-size:.9rem"><?= e(mb_substr($p['body'],0,140)) ?><?= mb_strlen($p['body'])>140?'…':'' ?></p>
      </div>
    </a>
  <?php endforeach; ?>
</div>
PHP

  cat > "$APP_DIR/views/admin.php" <<'PHP'
<?php /* @var array $users @var array $audit @var array $cats @var string $appName @var string $appTagline */ $lc = $_SESSION['ui_lang'] ?? 'tr'; ?>
<h1 style="margin:0 0 1.5rem;font-size:1.75rem">Admin</h1>

<div class="glass card" style="margin-bottom:1.5rem">
  <h2 style="margin:0 0 1rem;font-size:1.2rem"><?= e(t('admin_settings')) ?></h2>
  <form method="post" action="/admin.php" class="grid">
    <?= csrf_field() ?><input type="hidden" name="action" value="save_settings">
    <label class="text-sm">
      <span class="muted" style="display:block;margin-bottom:.35rem"><?= e(t('site_name')) ?></span>
      <input name="app_name" value="<?= e($appName) ?>" required maxlength="60">
    </label>
    <label class="text-sm">
      <span class="muted" style="display:block;margin-bottom:.35rem"><?= e(t('site_tagline')) ?></span>
      <input name="app_tagline" value="<?= e($appTagline) ?>" maxlength="160">
    </label>
    <button type="submit"><?= e(t('save')) ?></button>
  </form>
</div>

<div class="glass card" style="margin-bottom:1.5rem">
  <h2 style="margin:0 0 1rem;font-size:1.2rem"><?= e(t('admin_categories')) ?></h2>
  <div style="overflow-x:auto;margin-bottom:1rem">
    <table>
      <thead><tr><th>ID</th><th><?= e(t('icon')) ?></th><th><?= e(t('title')) ?></th><th>TR</th><th>EN</th><th><?= e(t('slug')) ?></th><th><?= e(t('position')) ?></th><th></th></tr></thead>
      <tbody>
        <?php foreach ($cats as $c): ?>
          <tr>
            <td><?= (int)$c['id'] ?></td>
            <td style="font-size:1.4rem"><?= e($c['icon']) ?></td>
            <td><a href="/category.php?slug=<?= e($c['slug']) ?>"><?= e(cat_name($c,$lc)) ?></a></td>
            <td><?= e($c['name_tr']) ?></td>
            <td><?= e($c['name_en']) ?></td>
            <td><code><?= e($c['slug']) ?></code></td>
            <td><?= (int)$c['position'] ?></td>
            <td>
              <div class="flex" style="gap:.35rem">
                <a href="/admin.php?edit_cat=<?= (int)$c['id'] ?>" class="btn-ghost btn btn-sm"><?= e(t('edit')) ?></a>
                <form method="post" action="/admin.php" style="margin:0" onsubmit="return confirm('<?= e(t('delete_confirm')) ?>')">
                  <?= csrf_field() ?>
                  <input type="hidden" name="action" value="delete_category">
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
  <details style="margin-top:1rem">
    <summary style="cursor:pointer;font-weight:600;color:var(--accent-400)">+ <?= e(t('add_category')) ?></summary>
    <form method="post" action="/admin.php" class="grid" style="margin-top:1rem">
      <?= csrf_field() ?><input type="hidden" name="action" value="add_category">
      <div class="flex flex-wrap" style="gap:.5rem">
        <input name="slug" placeholder="<?= e(t('slug')) ?>" required pattern="[a-z0-9\-]+" style="flex:1;min-width:120px">
        <input name="icon" placeholder="💬" maxlength="4" style="width:80px" value="💬">
        <input name="position" type="number" placeholder="<?= e(t('position')) ?>" style="width:100px" value="0">
      </div>
      <div class="flex flex-wrap" style="gap:.5rem">
        <input name="name_tr" placeholder="TR name" required style="flex:1;min-width:120px">
        <input name="name_en" placeholder="EN name" required style="flex:1;min-width:120px">
      </div>
      <div class="flex flex-wrap" style="gap:.5rem">
        <input name="description_tr" placeholder="TR description" style="flex:1;min-width:200px">
        <input name="description_en" placeholder="EN description" style="flex:1;min-width:200px">
      </div>
      <button type="submit"><?= e(t('add_category')) ?></button>
    </form>
  </details>
</div>

<?php if (!empty($_GET['edit_cat'])):
  $editId = (int)$_GET['edit_cat'];
  $st = $db->prepare('SELECT * FROM categories WHERE id=?'); $st->execute([$editId]); $ec = $st->fetch();
  if ($ec): ?>
<div class="glass card" style="margin-bottom:1.5rem">
  <h2 style="margin:0 0 1rem;font-size:1.2rem"><?= e(t('edit_category')) ?> #<?= (int)$ec['id'] ?></h2>
  <form method="post" action="/admin.php" class="grid">
    <?= csrf_field() ?><input type="hidden" name="action" value="edit_category">
    <input type="hidden" name="id" value="<?= (int)$ec['id'] ?>">
    <div class="flex flex-wrap" style="gap:.5rem">
      <input name="slug" value="<?= e($ec['slug']) ?>" required pattern="[a-z0-9\-]+" style="flex:1;min-width:120px">
      <input name="icon" value="<?= e($ec['icon']) ?>" maxlength="4" style="width:80px">
      <input name="position" type="number" value="<?= (int)$ec['position'] ?>" style="width:100px">
    </div>
    <div class="flex flex-wrap" style="gap:.5rem">
      <input name="name_tr" value="<?= e($ec['name_tr']) ?>" required style="flex:1;min-width:120px">
      <input name="name_en" value="<?= e($ec['name_en']) ?>" required style="flex:1;min-width:120px">
    </div>
    <div class="flex flex-wrap" style="gap:.5rem">
      <input name="name_fr" value="<?= e($ec['name_fr'] ?? '') ?>" placeholder="FR" style="flex:1;min-width:100px">
      <input name="name_de" value="<?= e($ec['name_de'] ?? '') ?>" placeholder="DE" style="flex:1;min-width:100px">
      <input name="name_es" value="<?= e($ec['name_es'] ?? '') ?>" placeholder="ES" style="flex:1;min-width:100px">
      <input name="name_ar" value="<?= e($ec['name_ar'] ?? '') ?>" placeholder="AR" style="flex:1;min-width:100px">
    </div>
    <input name="description_tr" value="<?= e($ec['description_tr'] ?? '') ?>" placeholder="TR description">
    <input name="description_en" value="<?= e($ec['description_en'] ?? '') ?>" placeholder="EN description">
    <div class="flex" style="gap:.5rem">
      <button type="submit"><?= e(t('save')) ?></button>
      <a href="/admin.php" class="btn-ghost btn"><?= e(t('back')) ?></a>
    </div>
  </form>
</div>
<?php endif; endif; ?>

<div class="glass card" style="margin-bottom:1.5rem">
  <h2 style="margin:0 0 1rem;font-size:1.2rem"><?= e(t('admin_users')) ?></h2>
  <form method="post" action="/admin.php" class="flex flex-wrap" style="margin-bottom:1rem">
    <?= csrf_field() ?><input type="hidden" name="action" value="bulk_role">
    <input name="ids" placeholder="1,2,3" style="flex:1;min-width:120px">
    <select name="role" style="width:auto"><option>member</option><option>moderator</option><option>admin</option></select>
    <button type="submit" class="btn-sm">Set role</button>
  </form>
  <div style="overflow-x:auto">
  <table><thead><tr><th>ID</th><th>User</th><th>Email</th><th>Role</th><th>Status</th></tr></thead><tbody>
    <?php foreach ($users as $u): ?>
      <tr>
        <td><?= (int)$u['id'] ?></td>
        <td><a href="/user.php?u=<?= e($u['username']) ?>">@<?= e($u['username']) ?></a></td>
        <td class="muted"><?= e($u['email']) ?></td>
        <td><span class="pill"><?= e($u['role']) ?></span></td>
        <td><?php if ((int)$u['banned']): ?><span class="pill pill-danger"><?= e(t('banned')) ?></span><?php else: ?>✓<?php endif; ?></td>
      </tr>
    <?php endforeach; ?>
  </tbody></table>
  </div>
</div>

<div class="glass card">
  <h2 style="margin:0 0 1rem;font-size:1.2rem"><?= e(t('admin_audit')) ?></h2>
  <div style="overflow-x:auto">
  <table><thead><tr><th>When</th><th>Actor</th><th>Action</th></tr></thead><tbody>
    <?php foreach ($audit as $a): ?>
      <tr><td class="muted"><?= date('Y-m-d H:i', (int)$a['ts']) ?></td><td><?= e($a['actor'] ?? '-') ?></td><td><?= e($a['action']) ?></td></tr>
    <?php endforeach; ?>
  </tbody></table>
  </div>
</div>
PHP

  cat > "$APP_DIR/views/404.php" <<'PHP'
<div class="hero">
  <h1 style="font-size:5rem;margin:0">404</h1>
  <p style="margin:1rem 0 2rem"><?= e(t('not_found')) ?></p>
  <a href="/" class="btn">← <?= e(t('home')) ?></a>
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
$recent = recent_topics($db, 10);
$stats = forum_stats($db);
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
      if ($u && password_verify_safe($pass,$u['password_hash'])) {
        if ((int)$u['banned'] === 1) { $error = t('banned_msg'); }
        else { auth_login($u); $next = $_GET['next'] ?? '/'; redirect($next); }
      } else { $error=t('bad_credentials'); }
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
        $db->prepare('INSERT INTO users(username,email,password_hash,created_at,last_seen_at) VALUES(?,?,?,?,?)')
           ->execute([$u,$em,password_hash_safe($p),time(),time()]);
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

  cat > "$APP_DIR/public/forgot-password.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$error=''; $sent=false;
if ($_SERVER['REQUEST_METHOD']==='POST') {
  csrf_verify();
  if (!rate_limit($db,'reset',client_ip(),$config['rate_limit']['reset_per_hr'],3600)) {
    http_response_code(429); $error=t('too_many_attempts');
  } else {
    $email = filter_var($_POST['email']??'', FILTER_VALIDATE_EMAIL);
    if ($email) {
      $st = $db->prepare('SELECT id, username FROM users WHERE email=?');
      $st->execute([$email]); $row = $st->fetch();
      if ($row) {
        $token = generate_reset_token($db, (int)$row['id']);
        $url = $config['base_url'] . '/reset-password.php?token=' . $token;
        $body = t('reset_password') . ":\n\n$url\n\n" . date('Y-m-d H:i');
        send_mail($email, 'Password reset', $body);
      }
    }
    $sent = true;
  }
}
ob_start(); require LF_ROOT.'/views/forgot-password.php'; $content=ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/reset-password.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$error='';
$token = (string)($_GET['token'] ?? $_POST['token'] ?? '');
if ($token === '') { http_response_code(400); $error = t('reset_invalid'); }
if ($_SERVER['REQUEST_METHOD']==='POST' && $token !== '') {
  csrf_verify();
  $p1 = (string)($_POST['password'] ?? '');
  $p2 = (string)($_POST['password2'] ?? '');
  if (strlen($p1) < 10) $error = t('weak_password');
  elseif ($p1 !== $p2) $error = t('password_mismatch');
  else {
    $uid = consume_reset_token($db, $token);
    if (!$uid) $error = t('reset_invalid');
    else {
      $db->prepare('UPDATE users SET password_hash=? WHERE id=?')->execute([password_hash_safe($p1), $uid]);
      flash_set('ok', t('reset_complete'));
      redirect('/login.php');
    }
  }
}
ob_start(); require LF_ROOT.'/views/reset-password.php'; $content=ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/category.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$slug = trim((string)($_GET['slug'] ?? ''));
if ($slug === '') { http_response_code(400); exit('Missing slug'); }
$st = $db->prepare('SELECT * FROM categories WHERE slug = ?');
$st->execute([$slug]); $cat = $st->fetch();
if (!$cat) { http_response_code(404); require LF_ROOT.'/views/404.php'; exit; }
$page = max(1, (int)($_GET['page'] ?? 1));
$per = 25; $off = ($page - 1) * $per;
$cnt = $db->prepare('SELECT COUNT(*) FROM topics WHERE category_id=?'); $cnt->execute([(int)$cat['id']]);
$total = (int)$cnt->fetchColumn();
$tst = $db->prepare(
  'SELECT t.*, u.username, u.avatar_color, (SELECT COUNT(*) FROM posts p WHERE p.topic_id = t.id AND p.is_deleted=0) AS post_count
   FROM topics t JOIN users u ON u.id = t.user_id
   WHERE t.category_id = ? ORDER BY t.is_pinned DESC, t.updated_at DESC LIMIT ? OFFSET ?'
);
$tst->execute([(int)$cat['id'], $per, $off]);
$topics = $tst->fetchAll();
$title = cat_name($cat, $_SESSION['ui_lang'] ?? 'tr');
ob_start(); require LF_ROOT.'/views/category.php'; $content = ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/topic.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$id = (int)($_GET['id'] ?? 0);
if ($id <= 0) { http_response_code(400); exit('Missing id'); }
$tst = $db->prepare('SELECT t.*, u.username, c.slug AS cat_slug FROM topics t JOIN users u ON u.id=t.user_id JOIN categories c ON c.id=t.category_id WHERE t.id=?');
$tst->execute([$id]); $topic = $tst->fetch();
if (!$topic) { http_response_code(404); require LF_ROOT.'/views/404.php'; exit; }
$skey = 'viewed_' . $id;
if (empty($_SESSION[$skey])) {
  $db->prepare('UPDATE topics SET views=views+1 WHERE id=?')->execute([$id]);
  $_SESSION[$skey] = true;
  $topic['views'] = (int)$topic['views'] + 1;
}
$catSt = $db->prepare('SELECT * FROM categories WHERE id=?'); $catSt->execute([(int)$topic['category_id']]);
$cat = $catSt->fetch();
$topic['cat_name'] = cat_name($cat, $_SESSION['ui_lang'] ?? 'tr');

$u = auth_user();
if ($_SERVER['REQUEST_METHOD']==='POST' && $u) {
  csrf_verify();
  $action = $_POST['action'] ?? '';
  if ($action === 'toggle_watch') {
    $w = $db->prepare('SELECT 1 FROM topic_watches WHERE user_id=? AND topic_id=?');
    $w->execute([(int)$u['id'], $id]);
    if ($w->fetchColumn()) {
      $db->prepare('DELETE FROM topic_watches WHERE user_id=? AND topic_id=?')->execute([(int)$u['id'], $id]);
      flash_set('ok', 'Takip bırakıldı.');
    } else {
      $db->prepare('INSERT INTO topic_watches(user_id,topic_id,created_at) VALUES(?,?,?)')->execute([(int)$u['id'], $id, time()]);
      flash_set('ok', 'Takip ediliyor.');
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

$pst = $db->prepare('SELECT p.*, u.username, u.avatar_color FROM posts p JOIN users u ON u.id=p.user_id WHERE p.topic_id=? ORDER BY p.created_at ASC');
$pst->execute([$id]); $posts = $pst->fetchAll();

$reactions = [];
$myReacted = [];
if (!empty($posts)) {
  $pids = array_map(fn($p) => (int)$p['id'], $posts);
  $ph = implode(',', array_fill(0, count($pids), '?'));
  $rs = $db->prepare("SELECT post_id, emoji, COUNT(*) AS c FROM post_reactions WHERE post_id IN ($ph) GROUP BY post_id, emoji");
  $rs->execute($pids);
  foreach ($rs->fetchAll() as $r) { $reactions[(int)$r['post_id']][$r['emoji']] = (int)$r['c']; }
  if ($u) {
    $rs2 = $db->prepare("SELECT post_id, emoji FROM post_reactions WHERE user_id=? AND post_id IN ($ph)");
    $rs2->execute(array_merge([(int)$u['id']], $pids));
    foreach ($rs2->fetchAll() as $r) { $myReacted[(int)$r['post_id']][] = $r['emoji']; }
  }
}

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
if (!$cat) { http_response_code(404); require LF_ROOT.'/views/404.php'; exit; }
$error = '';
if ($_SERVER['REQUEST_METHOD']==='POST') {
  csrf_verify();
  $title = trim((string)($_POST['title'] ?? ''));
  $body  = trim((string)($_POST['body'] ?? ''));
  if (strlen($title) < 3 || $body === '') $error = 'Başlık ve içerik gerekli.';
  elseif (!rate_limit($db,'post',client_ip(),$config['rate_limit']['post_per_min'],60)) $error = 'Çok hızlı. Biraz bekleyin.';
  else {
    $slug = preg_replace('/[^a-z0-9]+/', '-', strtolower($title));
    $db->prepare('INSERT INTO topics(category_id,user_id,title,slug,created_at,updated_at) VALUES(?,?,?,?,?,?)')
       ->execute([$catId, (int)$u['id'], $title, $slug, time(), time()]);
    $tid = (int)$db->lastInsertId();
    $db->prepare('INSERT INTO posts(topic_id,user_id,body,created_at,updated_at) VALUES(?,?,?,?,?)')
       ->execute([$tid, (int)$u['id'], $body, time(), time()]);
    redirect('/topic.php?id='.$tid);
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
$title = t('search');
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
$error = '';
if ($_SERVER['REQUEST_METHOD']==='POST') {
  csrf_verify();
  $action = $_POST['action'] ?? 'profile';
  if ($action === 'profile') {
    $bio = mb_substr(trim((string)($_POST['bio'] ?? '')), 0, 500);
    $theme = in_array($_POST['theme']??'', $config['themes'], true) ? $_POST['theme'] : 'dark';
    $accent = in_array($_POST['accent']??'', $config['accents'], true) ? $_POST['accent'] : 'indigo';
    $avatarColor = preg_match('/^#[0-9a-fA-F]{6}$/', $_POST['avatar_color'] ?? '') ? $_POST['avatar_color'] : '#6366f1';
    $nm = isset($_POST['notify_mentions']) ? 1 : 0;
    $nr = isset($_POST['notify_replies']) ? 1 : 0;
    $nx = isset($_POST['notify_reactions']) ? 1 : 0;
    $nd = isset($_POST['notify_digest']) ? 1 : 0;
    $db->prepare('UPDATE users SET bio=?, theme=?, accent=?, avatar_color=?, notify_mentions=?, notify_replies=?, notify_reactions=?, notify_digest=? WHERE id=?')
       ->execute([$bio, $theme, $accent, $avatarColor, $nm, $nr, $nx, $nd, (int)$u['id']]);
    $_SESSION['user']['theme'] = $theme;
    $_SESSION['user']['accent'] = $accent;
    $_SESSION['user']['bio'] = $bio;
    $_SESSION['user']['avatar_color'] = $avatarColor;
    $_SESSION['user']['notify_mentions'] = $nm;
    $_SESSION['user']['notify_replies'] = $nr;
    $_SESSION['user']['notify_reactions'] = $nx;
    $_SESSION['user']['notify_digest'] = $nd;
    audit($db, $u, 'user.settings_update');
    flash_set('ok', t('settings_saved'));
    redirect('/settings.php');
  } elseif ($action === 'password') {
    $cur = (string)($_POST['current_password'] ?? '');
    $new = (string)($_POST['new_password'] ?? '');
    $conf = (string)($_POST['confirm_password'] ?? '');
    if (!password_verify_safe($cur, $user['password_hash'])) $error = t('password_wrong');
    elseif (strlen($new) < 10) $error = t('weak_password');
    elseif ($new !== $conf) $error = t('password_mismatch');
    else {
      $db->prepare('UPDATE users SET password_hash=? WHERE id=?')->execute([password_hash_safe($new), (int)$u['id']]);
      audit($db, $u, 'user.password_change');
      flash_set('ok', t('password_changed'));
      redirect('/settings.php');
    }
  }
}
$title = t('settings');
ob_start(); require LF_ROOT.'/views/settings.php'; $content = ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/user.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$uname = trim((string)($_GET['u'] ?? ''));
if ($uname === '') { http_response_code(400); exit('Missing username'); }
$st = $db->prepare('SELECT * FROM users WHERE username=?');
$st->execute([$uname]); $profile = $st->fetch();
if (!$profile) { http_response_code(404); require LF_ROOT.'/views/404.php'; exit; }
$tst = $db->prepare('SELECT t.*, c.slug AS cat_slug FROM topics t JOIN categories c ON c.id=t.category_id WHERE t.user_id=? ORDER BY t.updated_at DESC LIMIT 20');
$tst->execute([(int)$profile['id']]); $topics = $tst->fetchAll();
foreach ($topics as &$t) {
  $catSt = $db->prepare('SELECT * FROM categories WHERE id=?'); $catSt->execute([(int)$t['category_id']]);
  $cat = $catSt->fetch();
  $t['cat_name'] = cat_name($cat, $_SESSION['ui_lang'] ?? 'tr');
}
$pst = $db->prepare('SELECT p.*, t.title AS topic_title FROM posts p JOIN topics t ON t.id=p.topic_id WHERE p.user_id=? AND p.is_deleted=0 ORDER BY p.created_at DESC LIMIT 20');
$pst->execute([(int)$profile['id']]); $posts = $pst->fetchAll();
$title = '@' . $profile['username'];
ob_start(); require LF_ROOT.'/views/user.php'; $content = ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/stats.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$stats = forum_stats($db);
$topUsers = $db->query('SELECT u.username, u.avatar_color, COUNT(p.id) AS cnt FROM users u LEFT JOIN posts p ON p.user_id=u.id WHERE p.is_deleted=0 GROUP BY u.id ORDER BY cnt DESC LIMIT 10')->fetchAll();
$title = t('stats');
ob_start(); require LF_ROOT.'/views/stats.php'; $content = ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/activity.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
$topics = recent_topics($db, 15);
$posts = recent_posts($db, 15);
$title = t('activity');
ob_start(); require LF_ROOT.'/views/activity.php'; $content = ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  cat > "$APP_DIR/public/react.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
if ($_SERVER['REQUEST_METHOD']!=='POST') { http_response_code(405); exit; }
$u = auth_require();
csrf_verify();
$postId = (int)($_POST['post_id'] ?? 0);
$emoji = (string)($_POST['emoji'] ?? '');
$back = (string)($_POST['back'] ?? '/');
if ($postId > 0 && in_array($emoji, ['👍','❤️','🔥','😂','😮'], true)
    && rate_limit($db,'react',client_ip(),$config['rate_limit']['react_per_min'],60)) {
  $st = $db->prepare('SELECT 1 FROM post_reactions WHERE post_id=? AND user_id=? AND emoji=?');
  $st->execute([$postId, (int)$u['id'], $emoji]);
  $exists = (bool)$st->fetchColumn();
  if ($exists) {
    $db->prepare('DELETE FROM post_reactions WHERE post_id=? AND user_id=? AND emoji=?')->execute([$postId, (int)$u['id'], $emoji]);
  } else {
    $db->prepare('INSERT INTO post_reactions(post_id,user_id,emoji,created_at) VALUES(?,?,?,?)')->execute([$postId, (int)$u['id'], $emoji, time()]);
    notif_for_reaction($db, $postId, (int)$u['id'], $emoji);
  }
}
redirect($back);
PHP

  cat > "$APP_DIR/public/mod.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
if ($_SERVER['REQUEST_METHOD']!=='POST') { http_response_code(405); exit; }
$u = auth_mod();
csrf_verify();
$action = $_POST['action'] ?? '';
$topicId = (int)($_POST['topic_id'] ?? 0);
$postId = (int)($_POST['post_id'] ?? 0);
$userId = (int)($_POST['user_id'] ?? 0);
$state = (int)($_POST['state'] ?? 0);

if ($action === 'pin' && $topicId > 0) {
  $db->prepare('UPDATE topics SET is_pinned=? WHERE id=?')->execute([$state, $topicId]);
  audit($db, $u, $state ? 'topic.pin' : 'topic.unpin', 'topic', $topicId);
  flash_set('ok', t('saved'));
  redirect('/topic.php?id=' . $topicId);
}
if ($action === 'lock' && $topicId > 0) {
  $db->prepare('UPDATE topics SET is_locked=? WHERE id=?')->execute([$state, $topicId]);
  audit($db, $u, $state ? 'topic.lock' : 'topic.unlock', 'topic', $topicId);
  flash_set('ok', t('saved'));
  redirect('/topic.php?id=' . $topicId);
}
if ($action === 'delete_post' && $postId > 0) {
  $st = $db->prepare('SELECT user_id, topic_id FROM posts WHERE id=?'); $st->execute([$postId]);
  $p = $st->fetch();
  if ($p && (is_admin($u) || (int)$p['user_id'] === (int)$u['id'])) {
    $db->prepare('UPDATE posts SET is_deleted=1 WHERE id=?')->execute([$postId]);
    audit($db, $u, 'post.delete', 'post', $postId);
  }
  $backTopic = $p ? (int)$p['topic_id'] : $topicId;
  flash_set('ok', t('saved'));
  redirect('/topic.php?id=' . $backTopic);
}
if ($action === 'delete_topic' && $topicId > 0) {
  if (!is_admin($u)) { http_response_code(403); exit(t('mod_only')); }
  $st = $db->prepare('SELECT category_id FROM topics WHERE id=?'); $st->execute([$topicId]);
  $catId = $st->fetchColumn();
  $db->prepare('DELETE FROM topics WHERE id=?')->execute([$topicId]);
  audit($db, $u, 'topic.delete', 'topic', $topicId);
  flash_set('ok', t('saved'));
  if ($catId) {
    $cs = $db->prepare('SELECT slug FROM categories WHERE id=?'); $cs->execute([(int)$catId]);
    $slug = $cs->fetchColumn();
    redirect('/category.php?slug=' . urlencode((string)$slug));
  }
  redirect('/');
}
if ($action === 'ban_user' && $userId > 0) {
  if (!is_admin($u)) { http_response_code(403); exit(t('mod_only')); }
  $db->prepare('UPDATE users SET banned=? WHERE id=?')->execute([$state, $userId]);
  audit($db, $u, $state ? 'user.ban' : 'user.unban', 'user', $userId);
  flash_set('ok', t('saved'));
  $st = $db->prepare('SELECT username FROM users WHERE id=?'); $st->execute([$userId]);
  $uname = $st->fetchColumn();
  redirect('/user.php?u=' . urlencode((string)$uname));
}
redirect('/');
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
    flash_set('ok', 'Roles updated.');
  } elseif ($action === 'save_settings') {
    $name = trim((string)($_POST['app_name'] ?? ''));
    $tagline = trim((string)($_POST['app_tagline'] ?? ''));
    if ($name !== '') settings_set($db, 'app_name', mb_substr($name, 0, 60));
    settings_set($db, 'app_tagline', mb_substr($tagline, 0, 160));
    audit($db, $u, 'site.settings');
    flash_set('ok', t('settings_saved'));
  } elseif ($action === 'add_category') {
    $slug = preg_replace('/[^a-z0-9\-]/', '', strtolower($_POST['slug'] ?? ''));
    $nameTr = trim((string)($_POST['name_tr'] ?? ''));
    $nameEn = trim((string)($_POST['name_en'] ?? ''));
    if ($slug && $nameTr && $nameEn) {
      try {
        $db->prepare('INSERT INTO categories(slug,name_tr,name_en,description_tr,description_en,icon,position) VALUES(?,?,?,?,?,?,?)')
           ->execute([$slug, $nameTr, $nameEn,
                      (string)($_POST['description_tr'] ?? ''),
                      (string)($_POST['description_en'] ?? ''),
                      mb_substr((string)($_POST['icon'] ?? '💬'), 0, 4),
                      (int)($_POST['position'] ?? 0)]);
        audit($db, $u, 'category.create', 'category', (int)$db->lastInsertId());
        flash_set('ok', t('saved'));
      } catch (PDOException) {
        flash_set('err', t('already_exists'));
      }
    }
  } elseif ($action === 'edit_category') {
    $id = (int)($_POST['id'] ?? 0);
    $slug = preg_replace('/[^a-z0-9\-]/', '', strtolower($_POST['slug'] ?? ''));
    if ($id > 0 && $slug) {
      $db->prepare('UPDATE categories SET slug=?, name_tr=?, name_en=?, name_fr=?, name_de=?, name_es=?, name_ar=?, description_tr=?, description_en=?, icon=?, position=? WHERE id=?')
         ->execute([$slug,
                    (string)($_POST['name_tr'] ?? ''),
                    (string)($_POST['name_en'] ?? ''),
                    (string)($_POST['name_fr'] ?? ''),
                    (string)($_POST['name_de'] ?? ''),
                    (string)($_POST['name_es'] ?? ''),
                    (string)($_POST['name_ar'] ?? ''),
                    (string)($_POST['description_tr'] ?? ''),
                    (string)($_POST['description_en'] ?? ''),
                    mb_substr((string)($_POST['icon'] ?? '💬'), 0, 4),
                    (int)($_POST['position'] ?? 0),
                    $id]);
      audit($db, $u, 'category.update', 'category', $id);
      flash_set('ok', t('saved'));
    }
  } elseif ($action === 'delete_category') {
    $id = (int)($_POST['id'] ?? 0);
    if ($id > 0) {
      $db->prepare('DELETE FROM categories WHERE id=?')->execute([$id]);
      audit($db, $u, 'category.delete', 'category', $id);
      flash_set('ok', t('saved'));
    }
  }
  redirect('/admin.php');
}
$users = $db->query('SELECT id,username,email,role,banned FROM users ORDER BY id DESC LIMIT 200')->fetchAll();
$cats  = $db->query('SELECT * FROM categories ORDER BY position, id')->fetchAll();
$audit = $db->query('SELECT a.*, u.username AS actor FROM audit_log a LEFT JOIN users u ON u.id=a.actor_id ORDER BY a.ts DESC LIMIT 50')->fetchAll();
$appName = $GLOBALS['__app_name'];
$appTagline = $GLOBALS['__app_tagline'];
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
  $db->prepare('INSERT INTO users(username,email,password_hash,erendev_sub,created_at,last_seen_at) VALUES(?,?,?,?,?,?)')
     ->execute([$username,$email,password_hash_safe(bin2hex(random_bytes(24))),$sub,time(),time()]);
  $st=$db->prepare('SELECT * FROM users WHERE id=?'); $st->execute([$db->lastInsertId()]); $user=$st->fetch();
} else {
  $db->prepare('UPDATE users SET erendev_sub=? WHERE id=?')->execute([$sub,$user['id']]);
}
if ((int)$user['banned'] === 1) { http_response_code(403); exit(t('banned_msg')); }
auth_login($user); redirect('/');
PHP

  cat > "$APP_DIR/public/404.php" <<'PHP'
<?php
declare(strict_types=1);
require dirname(__DIR__).'/app/bootstrap.php';
http_response_code(404);
ob_start(); require LF_ROOT.'/views/404.php'; $content = ob_get_clean();
require LF_ROOT.'/views/layout.php';
PHP

  chown -R root:root "$APP_DIR/public"
  find "$APP_DIR/public" -type d -exec chmod 0755 {} \;
  find "$APP_DIR/public" -type f -exec chmod 0644 {} \;

  for f in index.php category.php topic.php new-topic.php login.php register.php search.php user.php stats.php activity.php react.php admin.php notifications.php settings.php mod.php forgot-password.php reset-password.php 404.php; do
    [[ -f "$APP_DIR/public/$f" ]] || die "CRITICAL: $APP_DIR/public/$f missing"
  done
  ok "public/ (all critical files verified)"
}

write_nginx() {
  install -d -o root -g root -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
  SOCK="/run/php/${PHP_VER}-fpm-liteforum.sock"
  HAS_TLS=0
  [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] && HAS_TLS=1
  [[ $SKIP_TLS -eq 1 ]] && HAS_TLS=0

  if [[ $HAS_TLS -eq 1 ]]; then
    cat > "/etc/nginx/sites-available/liteforum" <<NGINX
limit_req_zone \$binary_remote_addr zone=lf_login:10m rate=10r/m;

server {
  listen 80; listen [::]:80;
  server_name $DOMAIN;
  location /.well-known/acme-challenge/ { allow all; }
  location / { return 301 https://\$host\$request_uri; }
}
server {
  listen 443 ssl http2; listen [::]:443 ssl http2;
  server_name $DOMAIN;
  root $APP_DIR/public; index index.php;
  server_tokens off; charset utf-8;
  client_max_body_size 10m;
  ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers off;
  ssl_session_cache shared:SSL:10m;
  ssl_session_timeout 1d;
  add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
  add_header X-Frame-Options "DENY" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header Referrer-Policy "strict-origin-when-cross-origin" always;
  add_header Content-Security-Policy "default-src 'self'; img-src 'self' https://oauth2.erendev.xyz data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self' https://oauth2.erendev.xyz" always;
  location = /favicon.ico { access_log off; return 204; }
  location = /login.php { limit_req zone=lf_login burst=5 nodelay; fastcgi_pass unix:$SOCK; include fastcgi_params; fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name; fastcgi_param HTTP_PROXY ""; }
  location ~ \.php\$ {
    try_files \$uri =404;
    fastcgi_pass unix:$SOCK;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_param HTTP_PROXY "";
    fastcgi_read_timeout 30s;
  }
  location / { try_files \$uri \$uri/ /index.php?\$query_string; }
  location ~ /\.(?!well-known) { deny all; }
  location ~* \.(env|log|sqlite|db|sql|bak|ini|conf|md|git)\$ { deny all; }
  location ~ /(config|app|lang|views|storage)/ { deny all; }
  access_log $LOG_DIR/access.log; error_log $LOG_DIR/error.log warn;
}
NGINX
  else
    cat > "/etc/nginx/sites-available/liteforum" <<NGINX
limit_req_zone \$binary_remote_addr zone=lf_login:10m rate=10r/m;

server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name $DOMAIN;
  root $APP_DIR/public; index index.php;
  server_tokens off; charset utf-8;
  client_max_body_size 10m;
  add_header Content-Security-Policy "default-src 'self'; img-src 'self' https://oauth2.erendev.xyz data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self' https://oauth2.erendev.xyz" always;
  add_header X-Frame-Options "DENY" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header Referrer-Policy "strict-origin-when-cross-origin" always;
  location = /favicon.ico { access_log off; return 204; }
  location = /login.php { limit_req zone=lf_login burst=5 nodelay; fastcgi_pass unix:$SOCK; include fastcgi_params; fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name; fastcgi_param HTTP_PROXY ""; }
  location ~ \.php\$ {
    try_files \$uri =404;
    fastcgi_pass unix:$SOCK;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_param HTTP_PROXY "";
    fastcgi_read_timeout 30s;
  }
  location / { try_files \$uri \$uri/ /index.php?\$query_string; }
  location ~ /\.(?!well-known) { deny all; }
  location ~* \.(env|log|sqlite|db|sql|bak|ini|conf|md|git)\$ { deny all; }
  location ~ /(config|app|lang|views|storage)/ { deny all; }
  access_log $LOG_DIR/access.log; error_log $LOG_DIR/error.log warn;
}
NGINX
  fi

  ln -sf /etc/nginx/sites-available/liteforum /etc/nginx/sites-enabled/liteforum
  rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/liteforum.http
  ok "Nginx config ($([ $HAS_TLS -eq 1 ] && echo https || echo http))"
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
  ufw default deny incoming; ufw default allow outgoing
  ufw allow 22/tcp comment 'SSH'
  ufw allow 80/tcp comment 'HTTP'
  ufw allow 443/tcp comment 'HTTPS'
  ufw --force enable
  ok "UFW enabled"
}

setup_fail2ban() {
  install -d -o root -g root -m 0755 /etc/fail2ban/jail.d
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
  cat > /etc/nginx/sites-available/liteforum.http <<HTTP
server { listen 80; server_name $DOMAIN; root $APP_DIR/public;
  location /.well-known/acme-challenge/ { allow all; }
  location / { return 301 https://\$host\$request_uri; } }
HTTP
  ln -sf /etc/nginx/sites-available/liteforum.http /etc/nginx/sites-enabled/liteforum.http
  rm -f /etc/nginx/sites-enabled/liteforum
  nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
  if certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --non-interactive --redirect 2>&1 | tee -a "$INSTALL_LOG"; then
    ok "TLS issued"
    systemctl enable --now certbot.timer 2>/dev/null || true
  else
    warn "Certbot failed — continuing with HTTP"
    SKIP_TLS=1
  fi
  rm -f /etc/nginx/sites-enabled/liteforum.http
}

seed_data() {
  DB="$DATA_DIR/liteforum.db"
  sqlite3 "$DB" <<SQL
INSERT OR IGNORE INTO categories(slug,name_tr,name_en,name_fr,name_de,name_es,name_ar,description_tr,description_en,icon,position) VALUES
 ('general','Genel','General','Général','Allgemein','General','عام','Genel tartışmalar','General discussions','💬',10),
 ('announcements','Duyurular','Announcements','Annonces','Ankündigungen','Anuncios','إعلانات','Resmi duyurular','Official announcements','📢',20),
 ('support','Destek','Support','Support','Hilfe','Soporte','دعم','Yardım ve destek','Help and support','🛠️',30);
SQL
  HASH="$(php -r 'echo password_hash($argv[1], PASSWORD_ARGON2ID);' "$ADMIN_PASS")"
  sqlite3 "$DB" <<SQL
INSERT INTO users(username,email,password_hash,role,created_at,last_seen_at)
VALUES('admin','$ADMIN_EMAIL','$HASH','admin',strftime('%s','now'),strftime('%s','now'))
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
  local base="http://127.0.0.1"
  for path in "/" "/category.php?slug=general" "/login.php" "/register.php" "/activity.php" "/stats.php" "/forgot-password.php" "/admin.php" "/settings.php"; do
    if curl -fsS -H "Host: $DOMAIN" "$base$path" -o /dev/null 2>/dev/null; then
      ok "HTTP $path"
    else
      warn "HTTP $path FAILED — check /var/log/liteforum/error.log"
    fi
  done
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
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:80
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now liteforum-cloudflared >/dev/null 2>&1 || true

  CF_URL=""
  for _ in $(seq 1 30); do
    CF_URL="$(journalctl -u liteforum-cloudflared --no-pager -n 300 2>/dev/null \
      | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
    [[ -n "$CF_URL" ]] && break
    sleep 2
  done
  if [[ -z "$CF_URL" ]]; then
    warn "Tunnel URL not found — check: journalctl -u liteforum-cloudflared -n 50"
    return
  fi

  # Point the app's base_url and OAuth redirect at the tunnel URL
  sed -i "s|https://localhost|$CF_URL|g" "$APP_DIR/config/config.php"
  ok "Cloudflare tunnel: $CF_URL"
}

setup_cf_named() {
  [[ $CF_NAMED -eq 1 ]] || return 0
  install_cloudflared
  install -d -o root -g root -m 0700 /etc/liteforum
  ( umask 077; printf 'TUNNEL_TOKEN=%s\n' "$CF_TOKEN" > /etc/liteforum/cloudflared.env )
  chmod 0600 /etc/liteforum/cloudflared.env
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

  for _ in $(seq 1 30); do
    LOG="$(journalctl -u liteforum-cloudflared --no-pager -n 200 2>/dev/null || true)"
    if [[ "$LOG" == *"Registered tunnel connection"* ]]; then
      ok "Cloudflare tunnel connected"
      return
    fi
    sleep 2
  done
  warn "Tunnel connection not confirmed — check: journalctl -u liteforum-cloudflared -n 50"
}

setup_cf_login() {
  [[ $CF_LOGIN -eq 1 ]] || return 0
  install_cloudflared
  local TUNNEL_NAME="liteforum" TUNNEL_ID="" CRED_JSON LOG
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

  TUNNEL_ID="$(cloudflared tunnel list -o json 2>/dev/null | jq -r --arg n "$TUNNEL_NAME" '[.[] | select(.name==$n)][0].id // empty' || true)"
  if [[ -z "$TUNNEL_ID" ]]; then
    cloudflared tunnel create "$TUNNEL_NAME" >>"$INSTALL_LOG" 2>&1 || die "Tunnel create failed"
    TUNNEL_ID="$(cloudflared tunnel list -o json 2>/dev/null | jq -r --arg n "$TUNNEL_NAME" '[.[] | select(.name==$n)][0].id // empty' || true)"
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
    service: http://127.0.0.1:80
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

  for _ in $(seq 1 30); do
    LOG="$(journalctl -u liteforum-cloudflared --no-pager -n 200 2>/dev/null || true)"
    if [[ "$LOG" == *"Registered tunnel connection"* ]]; then
      ok "Cloudflare tunnel connected → https://$DOMAIN"
      return
    fi
    sleep 2
  done
  warn "Tunnel connection not confirmed — check: journalctl -u liteforum-cloudflared -n 50"
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
  Tunnel : $(if [[ $CF_NAMED -eq 1 ]]; then if [[ $CF_LOGIN -eq 1 ]]; then echo login; else echo named; fi; elif [[ $CLOUDFLARED -eq 1 ]]; then echo quick; else echo none; fi)
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
write_nginx
start_services
verify_site
setup_cloudflared
setup_cf_named
setup_cf_login
if [[ $CF_NAMED -eq 1 ]]; then PUBLIC_URL="https://$DOMAIN"
else PUBLIC_URL="${CF_URL:-$([ $SKIP_TLS -eq 1 ] && echo http || echo https)://$DOMAIN}"; fi

CRED_FILE="/root/liteforum-credentials.txt"
cat > "$CRED_FILE" <<EOF
LiteForum Installation
======================
URL             : $PUBLIC_URL
Tunnel          : $(if [[ $CF_NAMED -eq 1 ]]; then echo "cloudflared named tunnel (Cloudflare terminates TLS, no certbot)"; elif [[ $CLOUDFLARED -eq 1 ]]; then echo "cloudflared quick tunnel (URL changes on restart)"; else echo none; fi)
Install lang    : $LANG_CODE
ErenDev OAuth   : $([[ $LANG_CODE == tr ]] && echo "shown only when UI=tr" || echo "hidden (no credentials)")
Admin email     : $ADMIN_EMAIL
Admin password  : $ADMIN_PASS
App key         : $APP_KEY
OAuth client_id : $OAuth_CLIENT_ID
OAuth secret    : $OAuth_CLIENT_SECRET
DB              : $DATA_DIR/liteforum.db
Logs            : $LOG_DIR

Features (v3 — all):
  ✓ Multi-language UI (tr/en/fr/de/es/ar) — switcher in header
  ✓ Per-user theme + accent color + avatar color
  ✓ Site name + tagline editable from /admin.php
  ✓ Admin: category CRUD (add/edit/delete with all language names)
  ✓ Admin: user role management + ban/unban
  ✓ Admin: audit log
  ✓ Moderation: pin/unpin, lock/unlock, delete post/topic
  ✓ Notifications: mentions, replies, reactions (with per-user toggles)
  ✓ Reactions: 👍 ❤️ 🔥 😂 😮
  ✓ Password change from /settings.php
  ✓ Password reset via email (/forgot-password.php)
  ✓ User profiles with bio + avatar color
  ✓ FTS5 search with bm25 ranking + snippet highlighting
  ✓ Activity feed, stats page, online counter
  ✓ Markdown-lite in posts (bold, italic, code, links, quotes, mentions)
  ✓ Ban enforcement (blocked users cannot log in)
  ✓ Double-gated ErenDev OAuth (install=tr AND ui=tr)

Troubleshooting:
  sudo tail -30 /var/log/liteforum/error.log
  ls -la $APP_DIR/public/
  sudo systemctl status nginx $PHP_VER-fpm
EOF
chmod 0600 "$CRED_FILE"

echo
echo "============================================================"
echo " LiteForum ready → $PUBLIC_URL"
echo " Admin: $ADMIN_EMAIL / $ADMIN_PASS"
echo " Credentials: $CRED_FILE"
echo "============================================================"
