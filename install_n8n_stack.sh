#!/bin/bash

# Скрипт для автоматической установки n8n, PostgreSQL и pgAdmin на Ubuntu 24.04

# Проверка прав суперпользователя
if [ "$(id -u)" -ne 0 ]; then
   echo "Этот скрипт должен быть запущен от имени root" 
   exit 1
fi

# Запрос данных у пользователя
read -p "Введите имя домена (например, example.com): " DOMAIN
read -p "Введите email для SSL-сертификата: " EMAIL

# Данные для pgAdmin
read -p "Введите email для входа в pgAdmin: " PGADMIN_EMAIL
read -s -p "Введите пароль для входа в pgAdmin: " PGADMIN_PASSWORD
echo ""

# Данные для пользователя PostgreSQL
DB_USER="n8n_user"
DB_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)

# Подготовка системы
echo "Обновление системы..."
apt update && apt upgrade -y

# Установка необходимых пакетов
echo "Установка необходимых пакетов..."
apt install -y curl wget gnupg2 ca-certificates lsb-release apt-transport-https software-properties-common nginx certbot python3-certbot-nginx

# Установка Node.js
echo "Установка Node.js 18.x..."
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt install -y nodejs

# Установка n8n
echo "Установка n8n..."
npm install n8n -g

# Установка PostgreSQL
echo "Установка PostgreSQL..."
apt install -y postgresql postgresql-contrib

# Настройка PostgreSQL
echo "Настройка PostgreSQL..."
sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
sudo -u postgres psql -c "CREATE DATABASE n8n_data OWNER $DB_USER;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE n8n_data TO $DB_USER;"

# Установка векторного плагина для PostgreSQL
echo "Установка векторного плагина для PostgreSQL..."
apt install -y postgresql-14-pgvector || apt install -y postgresql-15-pgvector || apt install -y postgresql-16-pgvector

# Активация векторного расширения
sudo -u postgres psql -d n8n_data -c "CREATE EXTENSION IF NOT EXISTS vector;"

# Установка pgAdmin4
echo "Установка pgAdmin4..."
curl -fsSL https://www.pgadmin.org/static/packages_pgadmin_org.pub | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/pgadmin.gpg
echo "deb [signed-by=/etc/apt/trusted.gpg.d/pgadmin.gpg] https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/$(lsb_release -cs) pgadmin4 main" > /etc/apt/sources.list.d/pgadmin4.list
apt update
apt install -y pgadmin4-web

# Настройка pgAdmin4
echo "Настройка pgAdmin4..."
echo "yes" | /usr/pgadmin4/bin/setup-web.sh --email $PGADMIN_EMAIL --password $PGADMIN_PASSWORD

# Настройка Nginx для n8n
echo "Настройка Nginx для n8n..."
cat > /etc/nginx/sites-available/$DOMAIN.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://localhost:5678;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /pgadmin/ {
        proxy_pass http://localhost:5050/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Script-Name /pgadmin;
    }
}
EOF

# Активация конфигурации Nginx
ln -s /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

# Настройка pgAdmin конфигурации
cat > /etc/pgadmin4/pgadmin4_web.conf << EOF
import os
SERVER_MODE = True
SCRIPT_NAME = '/pgadmin'
EOF
systemctl restart apache2

# Получение SSL-сертификата
echo "Получение SSL-сертификата..."
certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email $EMAIL

# Создание systemd сервиса для n8n
echo "Создание systemd сервиса для n8n..."
cat > /etc/systemd/system/n8n.service << EOF
[Unit]
Description=n8n
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/n8n start
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Активация и запуск n8n
systemctl daemon-reload
systemctl enable n8n
systemctl start n8n

# Вывод информации для пользователя
echo "============================================"
echo "Установка успешно завершена!"
echo "============================================"
echo "n8n доступен по адресу: https://$DOMAIN"
echo "pgAdmin доступен по адресу: https://$DOMAIN/pgadmin"
echo ""
echo "Данные для подключения к PostgreSQL:"
echo "Хост: localhost"
echo "Порт: 5432"
echo "База данных: n8n_data"
echo "Пользователь: $DB_USER"
echo "Пароль: $DB_PASSWORD"
echo ""
echo "Данные для входа в pgAdmin:"
echo "Email: $PGADMIN_EMAIL"
echo "Пароль: $PGADMIN_PASSWORD"
echo "============================================"
echo "Для входа в n8n необходимо создать аккаунт при первом посещении."
echo "============================================"

# Сохранение данных в файл для дальнейшего использования
cat > ~/n8n_install_info.txt << EOF
=========== ИНФОРМАЦИЯ ОБ УСТАНОВКЕ N8N ==========
Дата установки: $(date)
Домен: $DOMAIN

n8n доступен по адресу: https://$DOMAIN
pgAdmin доступен по адресу: https://$DOMAIN/pgadmin

Данные для подключения к PostgreSQL:
Хост: localhost
Порт: 5432
База данных: n8n_data
Пользователь: $DB_USER
Пароль: $DB_PASSWORD

Данные для входа в pgAdmin:
Email: $PGADMIN_EMAIL
Пароль: $PGADMIN_PASSWORD
================================================
EOF

chmod 600 ~/n8n_install_info.txt
echo "Данные для доступа также сохранены в файле ~/n8n_install_info.txt"
