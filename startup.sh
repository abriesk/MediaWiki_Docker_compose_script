#!/bin/bash
set -e

PROJECT_NAME="mediwiki"
ROOT_DIR="$(pwd)"
PROD_DIR="$ROOT_DIR/prod"
WEB_DIR="$ROOT_DIR/web"

# -------------------------
# Show help or route option
# -------------------------
if [ $# -eq 0 ] || [ "$1" == "--help" ]; then
  echo "Usage: ./startup.sh [OPTION]"
  echo
  echo "Options:"
  echo "  --first-time     Create full project structure from scratch"
  echo "  --reset          Remove containers, clean volumes and reinitialize"
  echo "  --update         Pull new images and preserve database/files"
  echo "  --start          Start the MediaWiki stack"
  echo "  --reboot         Restart all services cleanly"
  echo "  --help           Show this help message"
  echo "  (no args)        Same as --help"
  exit 0
fi

if [ "$1" == "--start" ]; then
  echo "🚀 Starting MediaWiki Docker stack..."

  if [ ! -f .env ]; then
    echo "❌ Error: .env file not found. Please copy .env.example to .env and configure your environment variables."
    exit 1
  fi

  export $(grep -v '^#' .env | xargs)

  echo "📧 Generating msmtp configuration..."
  envsubst < ./prod/msmtp/msmtprc.template > ./prod/msmtp/msmtprc
  chmod 600 ./prod/msmtp/msmtprc

  echo "📦 Bootstrapping database and Redis cache..."
  docker compose up -d db redis

  echo "🕒 Waiting for database inside db container..."
  retries=10
  count=0
  until docker compose exec db mysqladmin ping -u"$DB_USER" -p"$DB_PASS" --silent; do
    count=$((count + 1))
    if [ $count -ge $retries ]; then
      echo "❌ Database did not become ready in time. Check credentials or container logs."
      exit 1
    fi
    echo "⏳ Waiting for DB to be ready... ($count/$retries)"
    sleep 2
  done

  if [ ! -f web/index.php ]; then
    echo "📥 No MediaWiki found in web/. Proceeding with fresh install..."
    docker compose up -d --build php
  else
    echo "✅ MediaWiki files found. Skipping fresh install."
  fi

  echo "🧩 Starting full stack (nginx, php, jobrunner, parsoid, msmtp)..."
  docker compose up -d nginx php jobrunner parsoid msmtp

  echo "✅ All services started. Visit your wiki at ${MW_SITE_URL:-http://localhost}"
fi

if [ "$1" == "--reboot" ]; then
  echo "🔁 Rebooting MediaWiki stack..."
  docker compose down
  docker compose up -d --build
  echo "✅ All services restarted. Visit your wiki at http://localhost"
  exit 0
fi

# -------------------------
# Bootstrap project layout
# -------------------------
if [ "$1" == "--first-time" ]; then
  echo "🛠️ Bootstrapping project structure..."

  if [ -d "$PROD_DIR" ] || [ -d "$WEB_DIR" ] || [ -f "$ROOT_DIR/docker-compose.yml" ]; then
    echo "⚠️ Warning: Project directories or files already exist."
    read -p "Do you want to delete existing files and regenerate everything? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
      echo "❌ Aborting. Please clean up manually or run with --reset."
      exit 1
    fi
    echo "🧹 Cleaning up old project structure..."
    sudo rm -rf "$PROD_DIR" "$WEB_DIR" "$ROOT_DIR/docker-compose.yml"
  fi

  mkdir -p $PROD_DIR/php-fpm
  mkdir -p $PROD_DIR/nginx
  mkdir -p $PROD_DIR/jobrunner
  mkdir -p $PROD_DIR/msmtp
  mkdir -p $PROD_DIR/parsoid
  mkdir -p logs
  mkdir -p web

  echo "📄 Writing .env.example..."
  cat > .env.example <<EOF
# Site configuration
MW_SITE_NAME=MyWiki
MW_SITE_LANG=en
MW_SITE_URL=http://localhost
MW_SITE_HOST=localhost

# Admin user
MW_ADMIN_USER=admin
MW_ADMIN_PASS=adminpass12@

# Database
DB_NAME=mediawiki
DB_USER=wikiuser
DB_PASS=wikipass
DB_ROOT_PASS=rootpass
DB_HOST=db

# Redis
REDIS_HOST=redis
REDIS_PORT=6379

# Mail/SMTP
MAIL_HOST=smtp.gmail.com
MAIL_PORT=587
MAIL_FROM=wiki@gmail.com
MAIL_USER=wiki@gmail.com
MAIL_PASS=your_app_password
EOF

  echo "📄 Writing docker-compose.yml..."
  cat > docker-compose.yml <<'EOF'
services:
  db:
    image: mariadb:10.11
    restart: always
    environment:
      MYSQL_DATABASE: ${DB_NAME}
      MYSQL_USER: ${DB_USER}
      MYSQL_PASSWORD: ${DB_PASS}
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASS}
    volumes:
      - db_data:/var/lib/mysql

  redis:
    image: redis:alpine
    restart: always

  php:
    build: ./prod/php-fpm
    volumes:
      - ./web:/var/www/html
    depends_on:
      - db
    environment:
      MW_SITE_HOST: ${MW_SITE_HOST}

  nginx:
    image: nginx:latest
    ports:
      - "80:80"
    volumes:
      - ./prod/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./web:/var/www/html:ro
    depends_on:
      - php
    environment:
      - MW_SITE_HOST=${MW_SITE_HOST}

  parsoid:
    build: ./prod/parsoid
    depends_on:
      - php

  msmtp:
    build: ./prod/msmtp
    volumes:
      - ./prod/msmtp/msmtprc:/etc/msmtprc:ro

  jobrunner:
    build: ./prod/jobrunner
    depends_on:
      - php
    volumes:
      - ./web:/var/www/html

volumes:
  db_data:
EOF

  echo "📄 Writing nginx.conf..."
  cat > prod/nginx/nginx.conf <<'EOF'
events {}
http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout  65;

    server {
        listen 80;
        server_name ${MW_SITE_HOST} _;

        root /var/www/html;

        access_log /var/log/nginx/access.log;
        error_log /var/log/nginx/error.log;

        location / {
            try_files $uri $uri/ /index.php?$query_string;
        }

        location ~ \.php$ {
            include fastcgi_params;
            fastcgi_pass php:9000;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        }

        location ~* \.(jpg|jpeg|png|gif|css|js|ico|svg|woff|woff2|ttf|eot|otf|mp4|webm|ogg)$ {
            expires 30d;
            access_log off;
        }
    }
}
EOF

  echo "📄 Writing msmtprc Dockerfile..."
  cat > prod/msmtp/Dockerfile <<'EOF' 
FROM alpine:latest

# Install msmtp and dependencies
RUN apk add --no-cache msmtp gettext ca-certificates

# Create and embed entrypoint.sh
RUN echo '#!/bin/sh' > /entrypoint.sh && \
    echo 'envsubst < /etc/msmtprc.template > /etc/msmtprc' >> /entrypoint.sh && \
    echo 'exec msmtpd' >> /entrypoint.sh && \
    chmod +x /entrypoint.sh

# Copy template msmtprc if needed later (volume or override)
COPY msmtprc.template /etc/msmtprc.template

ENTRYPOINT ["/entrypoint.sh"]
EOF
 

  echo "📄 Writing msmtprc.template..."
  cat > prod/msmtp/msmtprc.template <<'EOF'
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account default
host           ${MAIL_HOST}
port           ${MAIL_PORT}
from           ${MAIL_FROM}
auth           on
user           ${MAIL_USER}
password       ${MAIL_PASS}
EOF

  echo "📄 Writing Dockerfiles..."
  cat > prod/jobrunner/Dockerfile <<'EOF'
FROM php:8.2-cli

RUN apt-get update && apt-get install -y \
    git mariadb-client unzip imagemagick curl netcat-openbsd libonig-dev libicu-dev \
    && docker-php-ext-install mbstring mysqli intl

RUN mkdir -p /usr/local/etc/php && echo "\
display_errors = Off\n\
log_errors = On\n\
error_reporting = E_ALL\n\
error_log = /var/log/php/jobrunner.log\n\
memory_limit = 256M\n\
upload_max_filesize = 100M\n\
post_max_size = 100M\n\
max_execution_time = 60\n" > /usr/local/etc/php/php.ini

WORKDIR /var/www/html
EOF

  cat > prod/php-fpm/Dockerfile <<'EOF'
FROM php:8.2-fpm

RUN apt-get update && apt-get install -y \
    libicu-dev libjpeg-dev libpng-dev libzip-dev libonig-dev \
    unzip git mariadb-client imagemagick curl  netcat-openbsd \
    && docker-php-ext-install intl mbstring zip mysqli opcache gd

RUN curl -sS https://getcomposer.org/installer | php && \
    mv composer.phar /usr/local/bin/composer

RUN mkdir -p /usr/local/etc/php && echo "\
display_errors = Off\n\
log_errors = On\n\
error_reporting = E_ALL\n\
error_log = /var/log/php/php-fpm.log\n\
memory_limit = 256M\n\
upload_max_filesize = 100M\n\
post_max_size = 100M\n\
max_execution_time = 60\n\
" > /usr/local/etc/php/php.ini

COPY install-mediawiki.sh /install-mediawiki.sh
RUN chmod +x /install-mediawiki.sh

WORKDIR /var/www/html
ENTRYPOINT ["/install-mediawiki.sh"]
EOF

  cat > prod/php-fpm/install-mediawiki.sh <<'EOF'
#!/bin/bash
set -e

if [ -f "/var/www/html/LocalSettings.php" ]; then
  echo "✅ MediaWiki already installed, skipping setup."
  php-fpm
  exit 0
fi

echo "📥 Downloading MediaWiki..."
curl -L -o /tmp/mediawiki.tar.gz https://releases.wikimedia.org/mediawiki/1.43/mediawiki-1.43.1.tar.gz
cd /tmp && tar -xzf mediawiki.tar.gz
mv mediawiki-1.43.1/* /var/www/html

chown -R www-data:www-data /var/www/html

echo "🔧 Running composer install..."
cd /var/www/html
composer install --no-dev || echo "⚠️ Composer failed — make sure extensions are properly configured."

# Default fallbacks
: "${MW_SITE_NAME:=MyWiki}"
: "${MW_SITE_LANG:=en}"
: "${MW_SITE_URL:=http://localhost}"
: "${MW_ADMIN_USER:=admin}"
: "${MW_ADMIN_PASS:=adminpass12@}"
: "${DB_NAME:=mediawiki}"
: "${DB_USER:=wikiuser}"
: "${DB_PASS:=wikipass}"
: "${DB_HOST:=db}"

echo "🚀 Running install script..."
php maintenance/install.php \
  --dbname "$DB_NAME" \
  --dbuser "$DB_USER" \
  --dbpass "$DB_PASS" \
  --dbserver "$DB_HOST" \
  --lang "$MW_SITE_LANG" \
  --pass "$MW_ADMIN_PASS" \
  "$MW_SITE_NAME" "$MW_ADMIN_USER"


# Ensure correct ownership (fix for root-owned LocalSettings.php)
echo "🔐 Fixing ownership for /var/www/html..."
chown -R www-data:www-data /var/www/html
chmod -R  777 /var/www/html
# Fix incorrect wgScriptPath (e.g. /html)
sed -i "s|\$wgScriptPath = .*;|\$wgScriptPath = \"\";|" /var/www/html/LocalSettings.php
# ---- Patch LocalSettings.php ----
echo "?? Patching LocalSettings.php..."
mkdir -p /var/www/html/logs
chmod 777 /var/www/html/logs

# Replace static $wgServer and insert dynamic logic above it
sed -i '/\$wgServer/s|=.*|= "$scheme://$host";|' /var/www/html/LocalSettings.php
sed -i "/\$wgServer/i \\
\$scheme = isset(\$_SERVER['HTTPS']) && \$_SERVER['HTTPS'] !== 'off' ? 'https' : 'http';\\n\$host = \$_SERVER['HTTP_HOST'];" /var/www/html/LocalSettings.php

# Append custom configs
cat << 'INNER_EOF' >> /var/www/html/LocalSettings.php

// Redis
if (defined('CACHE_REDIS')) {
  \$wgMainCacheType = CACHE_REDIS;
  \$wgSessionCacheType = CACHE_REDIS;
  \$wgParserCacheType = CACHE_REDIS;
  \$wgMessageCacheType = CACHE_REDIS;
  \$wgLockManagers[] = [
    'name' => 'redis-lock-manager',
    'class' => 'RedisLockManager',
    'servers' => [ [ 'host' => '${REDIS_HOST}', 'port' => ${REDIS_PORT} ] ],
    'db' => 0,
    'logLevel' => \Psr\Log\LogLevel::INFO,
  ];
} else {
  \$wgMainCacheType = CACHE_NONE;
  \$wgSessionCacheType = CACHE_NONE;
  \$wgParserCacheType = CACHE_NONE;
  \$wgMessageCacheType = CACHE_NONE;
}

// Email
\$wgSMTP = [
  'host' => "${MAIL_HOST}",
  'IDHost' => "localhost",
  'port' => ${MAIL_PORT},
  'auth' => true,
  'username' => "${MAIL_USER}",
  'password' => "${MAIL_PASS}",
  'from' => "${MAIL_FROM}"
];

// Logging
\$wgDebugLogFile = "\$IP/logs/mediawiki-debug.log";
\$wgDebugToolbar = true;

// VisualEditor + Parsoid
wfLoadExtension('VisualEditor');
\$wgDefaultUserOptions['visualeditor-enable'] = 1;
\$wgVirtualRestConfig['modules']['parsoid'] = [
  'url' => 'http://parsoid:8000',
  'domain' => 'localhost',
  'prefix' => 'localhost'
];

// Path-based routing settings
\$wgScriptPath = "";
\$wgArticlePath = "/wiki/\$1";
\$wgUsePathInfo = true;
INNER_EOF

RUN echo "listen = 0.0.0.0:9000" > /usr/local/etc/php-fpm.d/zz-docker.conf

php-fpm

EOF

  cat > prod/parsoid/Dockerfile <<'EOF'
FROM node:18-slim

# Set metadata
LABEL maintainer="you@example.com"

# Environment
ENV PARSOID_HOME=/opt/parsoid

# Install Parsoid dependencies
RUN apt-get update && \
    apt-get install -y git curl && \
    rm -rf /var/lib/apt/lists/*

# Clone Parsoid
RUN git clone --depth=1 https://gerrit.wikimedia.org/r/mediawiki/services/parsoid "$PARSOID_HOME"

WORKDIR $PARSOID_HOME

# Install dependencies
RUN npm install --production

# Embed config.yaml via echo
RUN echo "services:" > config.yaml && \
    echo "  - module: lib/index.js" >> config.yaml && \
    echo "    entrypoint: apiServiceWorker" >> config.yaml && \
    echo "    conf:" >> config.yaml && \
    echo "      logging:" >> config.yaml && \
    echo "        level: info" >> config.yaml && \
    echo "      port: 8000" >> config.yaml && \
    echo "      localsettings:" >> config.yaml && \
    echo "        domains:" >> config.yaml && \
    echo "          localhost:" >> config.yaml && \
    echo "            host: http://nginx" >> config.yaml && \
    echo "            prefix: localhost" >> config.yaml

# Expose Parsoid port
EXPOSE 8000

# Start Parsoid with config
CMD ["npm", "start"]
EOF

  echo "✅ Project structure created. Run ./startup.sh --start to launch your stack."
  exit 0
fi