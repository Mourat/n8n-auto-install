#!/bin/bash

set -e

GREEN='\033[0;32m'
NC='\033[0m' # No Color

log_step() {
  echo -e "\n${GREEN}==> $1...${NC}"
}

# ========================
# Ввод данных
# ========================
log_step "🔧 Запрос параметров"

read -p "Введите домен для n8n и pgAdmin (например: example.com): " DOMAIN
read -p "Введите email для Let's Encrypt: " EMAIL
read -p "Введите логин для pgAdmin: " PGADMIN_USER
read -s -p "Введите пароль для pgAdmin: " PGADMIN_PASSWORD
echo

# ========================
# Создание структуры
# ========================
log_step "📁 Создание проекта и структуры каталогов"
mkdir -p ~/n8n-docker && cd ~/n8n-docker
mkdir -p certbot/www certbot/conf

# ========================
# docker-compose.yml
# ========================
log_step "📝 Создание docker-compose.yml"
cat > docker-compose.yml <<EOF
version: "3.8"

services:
  n8n:
    image: n8nio/n8n
    restart: always
    environment:
      WEBHOOK_URL: "https://${DOMAIN}/"
      N8N_HOST: "${DOMAIN}"
      N8N_PORT: 5678
      N8N_PROTOCOL: "https"
    ports:
      - "5678:5678"
    volumes:
      - ./n8n_data:/home/node/.n8n

  postgres:
    image: postgres:15
    restart: always
    environment:
      POSTGRES_USER: project_user
      POSTGRES_PASSWORD: project_pass
      POSTGRES_DB: projects_db
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    command: postgres -c 'shared_preload_libraries=pgvector'

  pgadmin:
    image: dpage/pgadmin4
    restart: always
    environment:
      PGADMIN_DEFAULT_EMAIL: "${PGADMIN_USER}"
      PGADMIN_DEFAULT_PASSWORD: "${PGADMIN_PASSWORD}"
    volumes:
      - ./pgadmin_data:/var/lib/pgadmin
    depends_on:
      - postgres

  nginx:
    image: nginx:latest
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certbot/www:/var/www/certbot
      - ./certbot/conf:/etc/letsencrypt
    depends_on:
      - n8n
      - pgadmin

  certbot:
    image: certbot/certbot
    volumes:
      - ./certbot/www:/var/www/certbot
      - ./certbot/conf:/etc/letsencrypt
    entrypoint: "/bin/sh -c 'trap exit TERM; while :; do sleep 1; done'"
EOF

# ========================
# nginx.conf
# ========================
log_step "📝 Создание nginx.conf"
cat > nginx.conf <<EOF
events {}

http {
    server {
        listen 80;
        server_name ${DOMAIN};

        location /.well-known/acme-challenge/ {
            root /var/www/certbot;
        }

        location / {
            return 301 https://\$host\$request_uri;
        }
    }

    server {
        listen 443 ssl;
        server_name ${DOMAIN};

        ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

        location / {
            proxy_pass http://n8n:5678;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location /pgadmin/ {
            proxy_pass http://pgadmin:80/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
}
EOF

# ========================
# Docker и Compose
# ========================
log_step "🐳 Проверка установки Docker и Docker Compose"

if ! command -v docker &> /dev/null; then
  log_step "Установка Docker..."
  sudo apt update && sudo apt install -y docker.io
  sudo systemctl enable docker --now
fi

if ! command -v docker-compose &> /dev/null; then
  log_step "Установка Docker Compose..."
  sudo apt install -y docker-compose
fi

# ========================
# Получение SSL-сертификата
# ========================
log_step "🔐 Получение SSL-сертификата с помощью certbot"
docker-compose run --rm certbot certonly \
  --webroot --webroot-path=/var/www/certbot \
  --email ${EMAIL} --agree-tos --no-eff-email \
  -d ${DOMAIN}

# ========================
# Запуск контейнеров
# ========================
log_step "🚀 Запуск всех контейнеров"
docker-compose up -d

# ========================
# Установка pgvector
# ========================
log_step "🧠 Установка расширения pgvector в PostgreSQL"
sleep 5
docker exec -i $(docker-compose ps -q postgres) psql -U project_user -d projects_db -c "CREATE EXTENSION IF NOT EXISTS vector;"

# ========================
# Вывод итоговой информации
# ========================
log_step "✅ Установка завершена!"

echo
echo "🌐 n8n доступен: https://${DOMAIN}/"
echo "🌐 pgAdmin доступен: https://${DOMAIN}/pgadmin"
echo
echo "🔑 PostgreSQL:"
echo "  Хост: postgres (внутри docker-сети)"
echo "  БД: projects_db"
echo "  Пользователь: project_user"
echo "  Пароль: project_pass"
echo
echo "🔐 Доступ к pgAdmin:"
echo "  Логин: ${PGADMIN_USER}"
echo "  Пароль: ${PGADMIN_PASSWORD}"
echo
