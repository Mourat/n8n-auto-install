#!/bin/bash

# Скрипт для автоматической установки n8n, PostgreSQL и pgAdmin на Ubuntu 24.04 
# с использованием Docker

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
DB_NAME="n8n_data"
PG_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)

# Настройка каталогов для данных
mkdir -p /opt/n8n_data
mkdir -p /opt/postgres_data
mkdir -p /opt/pgadmin_data

# Подготовка системы
echo "Обновление системы..."
apt update && apt upgrade -y

# Установка необходимых пакетов
echo "Установка необходимых пакетов..."
apt install -y curl wget gnupg2 ca-certificates lsb-release apt-transport-https software-properties-common nginx certbot python3-certbot-nginx

# Установка Docker и Docker Compose
echo "Установка Docker и Docker Compose..."
apt remove -y docker docker-engine docker.io containerd runc || true
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh

# Убедимся, что Docker сервис запущен
systemctl enable docker
systemctl start docker

# Установка Docker Compose
curl -L "https://github.com/docker/compose/releases/download/v2.20.3/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Проверяем открытые порты и закрываем конфликтующие
echo "Проверка портов..."
if lsof -i:5678 > /dev/null; then
    echo "Порт 5678 уже используется. Останавливаем сервис..."
    fuser -k 5678/tcp
fi

if lsof -i:5050 > /dev/null; then
    echo "Порт 5050 уже используется. Останавливаем сервис..."
    fuser -k 5050/tcp
fi

if lsof -i:5432 > /dev/null; then
    echo "Порт 5432 уже используется. Останавливаем сервис..."
    systemctl stop postgresql || true
    fuser -k 5432/tcp
fi

# Настройка UFW, если установлен
if command -v ufw > /dev/null; then
    echo "Настройка файрвола UFW..."
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 5678/tcp
    ufw allow 5050/tcp
    ufw allow 5432/tcp
fi

# Создаем docker-compose.yml файл
echo "Создание docker-compose.yml..."
cat > /opt/docker-compose.yml << EOF
version: '3.8'

services:
  n8n:
    container_name: n8n
    image: n8nio/n8n:latest
    restart: always
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - N8N_HOST=\${DOMAIN}
      - N8N_PROTOCOL=https
      - N8N_PORT=443
      - NODE_ENV=production
      - N8N_ENCRYPTION_KEY=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
      - WEBHOOK_URL=https://\${DOMAIN}/
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n_data
      - DB_POSTGRESDB_USER=\${DB_USER}
      - DB_POSTGRESDB_PASSWORD=\${DB_PASSWORD}
    volumes:
      - /opt/n8n_data:/home/node/.n8n
    networks:
      - n8n_network
    depends_on:
      - postgres

  postgres:
    container_name: postgres
    image: postgis/postgis:16-3.4
    restart: always
    environment:
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=\${PG_PASSWORD}
      - POSTGRES_DB=postgres
    volumes:
      - /opt/postgres_data:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:5432:5432"
    networks:
      - n8n_network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  pgadmin:
    container_name: pgadmin
    image: dpage/pgadmin4
    restart: always
    environment:
      - PGADMIN_DEFAULT_EMAIL=\${PGADMIN_EMAIL}
      - PGADMIN_DEFAULT_PASSWORD=\${PGADMIN_PASSWORD}
      - PGADMIN_CONFIG_ENHANCED_COOKIE_PROTECTION=True
      - PGADMIN_CONFIG_LOGIN_BANNER="Authorized users only!"
      - PGADMIN_CONFIG_CONSOLE_LOG_LEVEL=10
    volumes:
      - /opt/pgadmin_data:/var/lib/pgadmin
    ports:
      - "127.0.0.1:5050:80"
    networks:
      - n8n_network
    depends_on:
      - postgres

networks:
  n8n_network:
    driver: bridge
EOF

# Создание .env файла для docker-compose
cat > /opt/.env << EOF
DOMAIN=$DOMAIN
PGADMIN_EMAIL=$PGADMIN_EMAIL
PGADMIN_PASSWORD=$PGADMIN_PASSWORD
PG_PASSWORD=$PG_PASSWORD
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
EOF

# Настройка Nginx для n8n
echo "Настройка Nginx для n8n и pgAdmin..."
cat > /etc/nginx/sites-available/$DOMAIN.conf << EOF
server {
    listen 80;
    server_name $DOMAIN;

    client_max_body_size 100M;
    proxy_connect_timeout 600;
    proxy_send_timeout 600;
    proxy_read_timeout 600;
    send_timeout 600;

    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location /pgadmin/ {
        proxy_pass http://127.0.0.1:5050/;
        proxy_set_header Host \$host;
        proxy_set_header X-Script-Name /pgadmin;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Referer "";
        proxy_connect_timeout 600s;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        client_max_body_size 100M;
    }
}
EOF

# Активация конфигурации Nginx
ln -sf /etc/nginx/sites-available/$DOMAIN.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

# Получение SSL-сертификата
echo "Получение SSL-сертификата..."
certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email $EMAIL

# Остановка всех существующих контейнеров (если они есть)
cd /opt/
docker-compose -f docker-compose.yml down 2>/dev/null || true

# Удаление всех существующих контейнеров с такими же именами (если они есть)
docker rm -f n8n postgres pgadmin 2>/dev/null || true

# Запуск Docker Compose
echo "Запуск контейнеров..."
cd /opt/
docker-compose -f docker-compose.yml --env-file .env up -d

# Ожидание запуска контейнеров
echo "Ожидание запуска контейнеров..."
sleep 15

# Проверка статуса контейнеров
echo "Проверка статуса контейнеров..."
docker ps
docker logs postgres --tail 20
docker logs n8n --tail 20
docker logs pgadmin --tail 20

# Создание пользователя и базы данных
echo "Настройка базы данных PostgreSQL..."
docker exec -i postgres psql -U postgres << EOF
CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';
CREATE DATABASE $DB_NAME OWNER $DB_USER;
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
EOF

echo "Установка векторного расширения..."
docker exec -i postgres psql -U postgres -d $DB_NAME -c "CREATE EXTENSION IF NOT EXISTS vector;"

# Перезапуск n8n после настройки базы данных
echo "Перезапуск n8n..."
docker restart n8n
sleep 5
docker logs n8n --tail 20

# Настройка автозапуска
echo "Настройка автозапуска Docker Compose при загрузке системы..."
cat > /etc/systemd/system/docker-compose-n8n.service << EOF
[Unit]
Description=Docker Compose Application Service for n8n
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt
ExecStart=/usr/local/bin/docker-compose --env-file .env up -d
ExecStop=/usr/local/bin/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable docker-compose-n8n.service

# Тестирование работоспособности сервисов
echo "Тестирование доступности сервисов..."
echo "Проверка n8n (порт 5678):"
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:5678

echo "Проверка pgAdmin (порт 5050):"
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:5050

echo "Проверка Docker network:"
docker network inspect n8n_network

# Проверка Nginx
echo "Проверка конфигурации Nginx:"
nginx -t

# Перезапуск Nginx для применения всех настроек
systemctl restart nginx

# Вывод информации для пользователя
echo "============================================"
echo "Установка завершена!"
echo "============================================"
echo "n8n доступен по адресу: https://$DOMAIN"
echo "pgAdmin доступен по адресу: https://$DOMAIN/pgadmin"
echo ""
echo "Данные для подключения к PostgreSQL:"
echo "Хост: postgres (для n8n внутри Docker)"
echo "Хост: localhost (для локального подключения)"
echo "Порт: 5432"
echo "База данных: $DB_NAME"
echo "Пользователь: $DB_USER"
echo "Пароль: $DB_PASSWORD"
echo "Суперпользователь postgres: postgres"
echo "Пароль для postgres: $PG_PASSWORD"
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
Хост: postgres (внутри Docker)
Хост: localhost (с сервера)
Порт: 5432
База данных: $DB_NAME
Пользователь: $DB_USER
Пароль: $DB_PASSWORD

Суперпользователь базы данных:
Пользователь: postgres
Пароль: $PG_PASSWORD

Данные для входа в pgAdmin:
Email: $PGADMIN_EMAIL
Пароль: $PGADMIN_PASSWORD

Директории данных:
n8n: /opt/n8n_data
PostgreSQL: /opt/postgres_data
pgAdmin: /opt/pgadmin_data

Docker Compose файл: /opt/docker-compose.yml
Переменные окружения: /opt/.env

Решение проблем:
- Проверить статус контейнеров: 'docker ps'
- Просмотр логов: 'docker logs n8n' или 'docker logs pgadmin'
- Перезапуск сервисов: 'cd /opt && docker-compose restart'
- Перезагрузка сервисов с обновлением: 'cd /opt && docker-compose down && docker-compose up -d'
================================================
EOF

chmod 600 ~/n8n_install_info.txt
echo "Данные для доступа также сохранены в файле ~/n8n_install_info.txt"

# Создание скрипта диагностики
cat > ~/n8n_diagnostics.sh << 'EOF'
#!/bin/bash

echo "===== Диагностика сервисов n8n, PostgreSQL и pgAdmin ====="
echo "Статус Docker сервиса:"
systemctl status docker | grep Active

echo -e "\nСтатус контейнеров:"
docker ps -a

echo -e "\nЛоги n8n контейнера:"
docker logs n8n --tail 30

echo -e "\nЛоги pgAdmin контейнера:"
docker logs pgadmin --tail 30

echo -e "\nЛоги PostgreSQL контейнера:"
docker logs postgres --tail 30

echo -e "\nПроверка доступности портов:"
echo "n8n (5678):"
nc -zv localhost 5678 2>&1

echo "pgAdmin (5050):"
nc -zv localhost 5050 2>&1

echo "PostgreSQL (5432):"
nc -zv localhost 5432 2>&1

echo -e "\nСтатус Nginx:"
systemctl status nginx | grep Active

echo -e "\nПроверка конфигурации Nginx:"
nginx -t

echo -e "\nВиртуальные хосты Nginx:"
ls -la /etc/nginx/sites-enabled/

echo -e "\nПроверка сетевых интерфейсов Docker:"
docker network ls
docker network inspect n8n_network

echo -e "\nДиагностика завершена"
EOF

chmod +x ~/n8n_diagnostics.sh
echo "Создан скрипт диагностики ~/n8n_diagnostics.sh для устранения возможных проблем"
