#!/bin/bash

echo "📨 Введите домен, по которому будет доступен n8n (например: n8n.example.com):"
read DOMAIN

echo "✉️ Введите email для входа в pgAdmin (будет использоваться как логин):"
read PGADMIN_EMAIL

echo "🔐 Введите пароль для входа в pgAdmin:"
read -s PGADMIN_PASSWORD

echo "📦 Установка зависимостей..."
sudo apt update && sudo apt install -y curl gnupg2 ca-certificates lsb-release nginx software-properties-common certbot python3-certbot-nginx postgresql python3-pip

echo "⬇️ Установка Node.js 21 (через NodeSource)..."
curl -fsSL https://deb.nodesource.com/setup_21.x | sudo -E bash -
sudo apt install -y nodejs

echo "🛠 Установка n8n..."
sudo npm install -g n8n

echo "👤 Создание пользователя n8n..."
sudo useradd -r -m -s /usr/sbin/nologin n8n

echo "📁 Конфигурация n8n..."
sudo mkdir -p /etc/n8n
sudo tee /etc/n8n/.env > /dev/null <<EOF
N8N_HOST=$DOMAIN
N8N_PORT=5678
N8N_PROTOCOL=http

WEBHOOK_URL=https://$DOMAIN/
VUE_APP_URL_BASE_API=https://$DOMAIN/

N8N_USER_FOLDER=/home/n8n/.n8n
EOF

sudo mkdir -p /home/n8n/.n8n
sudo chown -R n8n:n8n /home/n8n

echo "📝 Создание службы systemd для n8n..."
sudo tee /etc/systemd/system/n8n.service > /dev/null <<EOF
[Unit]
Description=n8n workflow automation tool
After=network.target

[Service]
Type=simple
User=n8n
EnvironmentFile=/etc/n8n/.env
ExecStart=/usr/bin/n8n
Restart=always
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable n8n
sudo systemctl start n8n

echo "📚 Установка PostgreSQL..."
sudo -u postgres psql <<EOF
CREATE DATABASE n8n_data;
CREATE USER n8nuser WITH PASSWORD 'n8npass';
GRANT ALL PRIVILEGES ON DATABASE n8n_data TO n8nuser;
\c n8n_data
GRANT ALL ON SCHEMA public TO n8nuser;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO n8nuser;
EOF

sudo sed -i "s/^#listen_addresses = .*/listen_addresses = 'localhost'/" /etc/postgresql/*/main/postgresql.conf
sudo systemctl restart postgresql

echo "🧠 Установка pgAdmin 4 (standalone)..."
curl https://www.pgadmin.org/static/packages_pgadmin_org.pub | sudo gpg --dearmor -o /usr/share/keyrings/packages-pgadmin-org.gpg
sudo sh -c 'echo "deb [signed-by=/usr/share/keyrings/packages-pgadmin-org.gpg] https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/$(lsb_release -cs) pgadmin4 main" > /etc/apt/sources.list.d/pgadmin4.list'
sudo apt update
sudo apt install -y pgadmin4

echo "⚙️ Настройка pgAdmin с email и паролем..."
export PGADMIN_SETUP_EMAIL=$PGADMIN_EMAIL
export PGADMIN_SETUP_PASSWORD=$PGADMIN_PASSWORD
/usr/pgadmin4/bin/setup-web.sh --yes

echo "🧩 Создание systemd-сервиса для pgAdmin..."
sudo tee /etc/systemd/system/pgadmin4.service > /dev/null <<EOF
[Unit]
Description=pgAdmin 4 standalone service
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
ExecStart=/usr/pgadmin4/bin/pgadmin4
WorkingDirectory=/usr/pgadmin4
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable pgadmin4
sudo systemctl start pgadmin4

echo "🌐 Настройка nginx..."
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

    location /pgadmin/ {
        proxy_pass http://localhost:5050/;
        proxy_set_header X-Script-Name /pgadmin;
        proxy_set_header X-Scheme https;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

sudo ln -s /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

echo "🔐 Установка SSL (Let's Encrypt)..."
sudo certbot --nginx --non-interactive --agree-tos -m admin@$DOMAIN -d $DOMAIN

echo
echo "✅ Установка завершена!"
echo "🔗 Панель n8n:         https://$DOMAIN"
echo "🧩 Интерфейс pgAdmin:  https://$DOMAIN/pgadmin"
echo "     Email: $PGADMIN_EMAIL"
echo "     Пароль: (введён при установке)"
echo
echo "📦 Данные PostgreSQL:"
echo "     Хост: localhost"
echo "     Порт: 5432"
echo "     База: n8n_data"
echo "     Пользователь: n8nuser"
echo "     Пароль: n8npass"
