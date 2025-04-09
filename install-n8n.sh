#!/bin/bash

#chmod +x install-n8n.sh

echo "📨 Введите домен, по которому будет доступен n8n (например: n8n.example.com):"
read DOMAIN

echo "📦 Устанавливаем зависимости..."
sudo apt update && sudo apt install -y curl gnupg2 ca-certificates lsb-release nginx software-properties-common certbot python3-certbot-nginx postgresql

echo "⬇️ Установка nvm и последней версии Node.js..."
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash

export NVM_DIR="$HOME/.nvm"
source "$NVM_DIR/nvm.sh"
nvm install node

export NVM_NODE_VERSION=$(nvm version)
export NODE_PATH="$NVM_DIR/versions/node/$NVM_NODE_VERSION/bin/node"
export N8N_PATH="$NVM_DIR/versions/node/$NVM_NODE_VERSION/bin/n8n"

echo "🛠 Установка n8n..."
$NVM_DIR/versions/node/$NVM_NODE_VERSION/bin/npm install -g n8n

echo "👤 Создание системного пользователя n8n..."
sudo useradd -r -m -s /usr/sbin/nologin n8n

echo "📁 Создание конфигурации..."
sudo mkdir -p /etc/n8n
sudo tee /etc/n8n/.env > /dev/null <<EOF
N8N_HOST=$DOMAIN
N8N_PORT=5678
N8N_PROTOCOL=http

WEBHOOK_URL=https://$DOMAIN/
VUE_APP_URL_BASE_API=https://$DOMAIN/

N8N_USER_FOLDER=/home/n8n/.n8n
EOF

echo "📂 Права на папку пользователя..."
sudo mkdir -p /home/n8n/.n8n
sudo chown -R n8n:n8n /home/n8n

echo "📝 Создание systemd службы..."
sudo tee /etc/systemd/system/n8n.service > /dev/null <<EOF
[Unit]
Description=n8n workflow automation tool
After=network.target

[Service]
Type=simple
User=n8n
EnvironmentFile=/etc/n8n/.env
ExecStart=$N8N_PATH
Restart=always
Environment=PATH=$NVM_DIR/versions/node/$NVM_NODE_VERSION/bin:/usr/bin:/bin
Environment=NODE_ENV=production
Environment=NVM_DIR=$NVM_DIR

[Install]
WantedBy=multi-user.target
EOF

echo "🔄 Перезапуск systemd..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable n8n
sudo systemctl start n8n

echo "🌐 Настройка Nginx..."
sudo tee /etc/nginx/sites-available/n8n > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

sudo ln -s /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

echo "🔐 Получение SSL-сертификата..."
sudo certbot --nginx --non-interactive --agree-tos -m admin@$DOMAIN -d $DOMAIN

echo "🛠 Установка и настройка PostgreSQL..."
sudo -u postgres psql <<EOF
CREATE DATABASE n8n_data;
CREATE USER n8nuser WITH PASSWORD 'n8npass';
GRANT ALL PRIVILEGES ON DATABASE n8n_data TO n8nuser;
EOF

sudo sed -i "s/^#listen_addresses = .*/listen_addresses = 'localhost'/" /etc/postgresql/*/main/postgresql.conf
sudo systemctl restart postgresql

echo
echo "✅ Установка завершена!"
echo "🔗 Панель n8n доступна: https://$DOMAIN"
echo
echo "📦 Данные PostgreSQL (для workflow):"
echo "  Хост: localhost"
echo "  Порт: 5432"
echo "  База: n8n_data"
echo "  Пользователь: n8nuser"
echo "  Пароль: n8npass"
