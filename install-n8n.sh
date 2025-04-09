#!/bin/bash

#chmod +x install-n8n.sh

echo "📨 Введите домен, по которому будет доступен n8n (например: n8n.example.com):"
read DOMAIN

echo "📦 Устанавливаем зависимости..."
sudo apt update && sudo apt install -y curl gnupg2 ca-certificates lsb-release nginx software-properties-common certbot python3-certbot-nginx

echo "⬇️ Установка nvm и последней версии Node.js..."
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
export NVM_DIR="$HOME/.nvm"
source "$NVM_DIR/nvm.sh"
nvm install node

echo "🛠 Установка n8n..."
npm install -g n8n

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
NODE_PATH=$(which node)
N8N_PATH=$(which n8n)

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
Environment=PATH=$NVM_DIR/versions/node/$(nvm version)/bin:/usr/bin:/bin
Environment=NODE_ENV=production

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
sudo nginx -t
sudo systemctl reload nginx

echo "🔐 Получение SSL-сертификата..."
sudo certbot --nginx --non-interactive --agree-tos -m admin@$DOMAIN -d $DOMAIN

echo "✅ Установка завершена!"
echo "Открой в браузере: https://$DOMAIN"
echo "При первом заходе ты сможешь создать логин и пароль администратора."
