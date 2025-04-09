#!/bin/bash

set -e

GREEN='\033[0;32m'
NC='\033[0m'

log_step() {
  echo -e "\n${GREEN}==> $1...${NC}"
}

# ==== Ввод данных ====
log_step "🔧 Запрос параметров"
read -p "Введите домен для n8n и pgAdmin (например: example.com): " DOMAIN
read -p "Введите email для Let's Encrypt: " EMAIL
read -p "Введите логин для pgAdmin: " PGADMIN_USER
read -s -p "Введите пароль для pgAdmin: " PGADMIN_PASSWORD
echo

mkdir -p ~/n8n-docker && cd ~/n8n-docker
mkdir -p certbot/www certbot/conf

# ==== docker-compose.yml ====
log_step "📝 Создание docker-compose.yml"
cat > docker-compose.yml <<EOF
version: "3.8"

services:
  n8n
