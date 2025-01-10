#!/bin/bash

# Установка необходимых пакетов
if ! command -v unzip &> /dev/null; then
    echo "Устанавливаем unzip..."
    sudo apt update && sudo apt install unzip -y || { echo "Не удалось установить unzip."; exit 1; }
fi

if ! command -v docker &> /dev/null; then
    echo "Устанавливаем Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh || { echo "Не удалось установить Docker."; exit 1; }
    rm get-docker.sh
fi

if ! command -v docker-compose &> /dev/null; then
    echo "Устанавливаем Docker Compose..."
    sudo apt update && sudo apt install docker-compose-plugin -y || { echo "Не удалось установить Docker Compose."; exit 1; }
fi

# Добавление текущего пользователя в группу docker
if ! groups $USER | grep -q '\bdocker\b'; then
    echo "Добавляем пользователя $(whoami) в группу docker..."
    sudo usermod -aG docker $(whoami)
    newgrp docker
    echo "Для применения изменений перезайдите в систему или выполните 'newgrp docker'."
fi

# Проверка наличия buildx
if ! docker buildx version &> /dev/null; then
    echo "Устанавливаем buildx..."
    sudo apt install docker-buildx -y || { echo "Не удалось установить buildx."; exit 1; }
fi

# Запрос ссылки VPN
read -p "Введите ссылку на VPN (VLESS): " VPN_URL

# Разбор ссылки VPN
UUID=$(echo $VPN_URL | grep -oP '(?<=://)[^@]+')
SERVER=$(echo $VPN_URL | grep -oP '(?<=@)[^:]+')
PORT=$(echo $VPN_URL | grep -oP '(?<=:)[0-9]+')
SNI=$(echo $VPN_URL | grep -oP '(?<=sni=)[^&]+' | sed 's/#.*//')
NAME=$(echo $VPN_URL | grep -oP '(?<=#).*')

# Запрос доменов для исключения из проксирования
read -p "Введите через запятую домены для исключения из проксирования: " EXCLUDED_DOMAINS

# Скачивание и распаковка tun2socks
TUN2SOCKS_URL="https://github.com/xjasonlyu/tun2socks/releases/download/v2.5.2/tun2socks-linux-amd64.zip"
TUN2SOCKS_DIR="."

if [ ! -f "$TUN2SOCKS_DIR/tun2socks" ]; then
    echo "Скачиваем и распаковываем tun2socks..."
    curl -L -o tun2socks.zip $TUN2SOCKS_URL
    unzip -o tun2socks.zip -d $TUN2SOCKS_DIR
    chmod +x tun2socks-linux-amd64
    mv tun2socks-linux-amd64 tun2socks
    rm tun2socks.zip
fi

# Создание конфигурации V2Ray
mkdir -p v2ray-config
cat > v2ray-config/config.json <<EOF
{
  "log": {
    "loglevel": "info"
  },
  "inbounds": [
    {
      "port": 1080,
      "protocol": "socks",
      "settings": {
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$SERVER",
            "port": $PORT,
            "users": [
              {
                "id": "$UUID",
                "encryption": "none",
                "flow": "xtls-rprx-direct"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$SNI"
        }
      }
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "domain": ["$EXCLUDED_DOMAINS"],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

# Создание Docker сети
NETWORK_NAME="vpn-net-static"
NETWORK_SUBNET="172.18.0.0/16"
if ! docker network inspect $NETWORK_NAME &> /dev/null; then
    echo "Создаем Docker сеть $NETWORK_NAME..."
    docker network create -d bridge $NETWORK_NAME # --subnet=$NETWORK_SUBNET $NETWORK_NAME
fi

# Создание Dockerfile
cat > Dockerfile <<EOF
FROM v2fly/v2fly-core:latest
RUN apk add --no-cache curl
EOF

# Создание tun2.Dockerfile
cat > tun2.Dockerfile <<EOF
FROM alpine:latest
RUN apk add --no-cache iproute2 iptables bash curl
COPY $TUN2SOCKS_DIR/tun2socks /usr/local/bin/tun2socks
RUN chmod +x /usr/local/bin/tun2socks
EOF
#CMD [ "sh" ]

export DOCKER_BUILDKIT=1
# Этап 1: Построение образа V2Ray
echo "Сборка образа V2Ray..."
docker build -t v2ray:custom -f Dockerfile . || { echo "Не удалось собрать образ V2Ray."; exit 1; }
echo "Образ V2Ray успешно создан."

echo "Cleaning up unused build cache..."
sudo docker builder prune -a -f

# Этап 2: Построение образа tun2socks
echo "Сборка образа tun2socks..."
docker build -t tun2socks:custom -f tun2.Dockerfile . || { echo "Не удалось собрать образ tun2socks."; exit 1; }
echo "Образ tun2socks успешно создан."

echo "Cleaning up unused build cache..."
sudo docker builder prune -a -f

echo "Удаляем образы без имени..."
docker images -f "dangling=true" -q | xargs -r docker rmi || echo "Нет образов для удаления."


# Этап 3: Создание Docker Compose файла
echo "Создание Docker Compose файла..."
DOCKER_COMPOSE_FILE="docker-compose.yml"
cat > $DOCKER_COMPOSE_FILE <<EOF
services:
  v2ray:
    image: v2ray:custom
    container_name: v2ray-vless
    volumes:
      - ./v2ray-config:/etc/v2ray
    command: ["run", "-c", "/etc/v2ray/config.json"]
    networks:
      - vpn-net-static
    ports:
      - "1080:1080"
    restart: unless-stopped

  tun2socks:
    image: tun2socks:custom
    container_name: tun2socks
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    devices:
      - "/dev/net/tun:/dev/net/tun"
    networks:
      - vpn-net-static
    command: >
      sh -c "
        ip tuntap del dev tun0 mode tun || true;
        ip tuntap add dev tun0 mode tun || true;
        ip addr flush dev tun0 || true;
        ip addr add 10.0.0.1/24 dev tun0;
        ip link set dev tun0 up;
        ip route del default || true;
        ip route add default dev tun0 || true; 
        /usr/local/bin/tun2socks -device tun0 -proxy socks5://v2ray-vless:1080;
        tail -f /dev/null"
    restart: unless-stopped

networks:
  vpn-net-static:
    external: true
EOF

# Этап 4: Запуск контейнеров
echo "Запуск контейнеров..."
docker compose up -d || { echo "Не удалось запустить контейнеры."; exit 1; }
echo "Контейнеры успешно запущены."
sleep 3




# включение форварда
#sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

touch /etc/rc.local
chmod +x /etc/rc.local
systemctl enable rc-local
systemctl start rc-local
cat > /etc/rc.local <<EOF
#!/bin/bash

NETWORK_NAME="vpn-net-static"
MAIN_FACE=\$(ip route | grep default | awk '{print \$5}')
MAIN_IP=\$(ip -4 addr show \$MAIN_FACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
GATEWAY=\$(ip route | grep default | awk '{print \$3}')
NETWORK_ID=\$(docker network inspect \$NETWORK_NAME --format '{{.Id}}' | cut -c1-12)
CIDR=\$(ip -o -f inet addr show \$MAIN_FACE | awk '{print \$4}')
NETWORK=\$(echo \$CIDR | awk -F'/' '{split(\$1,ip,"."); prefix=\$2; print ip[1]"."ip[2]"."ip[3]".0/"prefix}')
BRIDGE_INTERFACE="br-\$NETWORK_ID"
TUN2SOCKS_IP=\$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' tun2socks)

if ip link show "\$BRIDGE_INTERFACE" > /dev/null 2>&1; then
    echo "Настройка маршрутов для \$BRIDGE_INTERFACE"

# Добавление правил ip rule
  echo "Проверяем и добавляем правило: from \$MAIN_IP lookup main"
  if ! ip rule list | grep -q "from \$MAIN_IP lookup main"; then
    echo "Добавляем правило: from \$MAIN_IP lookup main"
    ip rule add from \$MAIN_IP lookup main priority 50 || true
  else
    echo "Правило уже существует: from \$MAIN_IP lookup main"
  fi

  echo "Проверяем и добавляем правило: from \$NETWORK to 0.0.0.0/0 table 100"
  if ! ip rule list | grep -q "from \$NETWORK to 0.0.0.0/0 table 100"; then
    echo "Добавляем правило: from \$NETWORK to 0.0.0.0/0 table 100"
    ip rule add from \$NETWORK to 0.0.0.0/0 table 100 priority 100 || true
  else
    echo "Правило уже существует: from \$NETWORK to 0.0.0.0/0 table 100"
  fi

# Добавление маршрута
  echo "Проверяем и добавляем маршрут: default via \$TUN2SOCKS_IP"
  if ! ip route show table 100 | grep -q "default via \$TUN2SOCKS_IP"; then
    echo "Добавляем маршрут: default via $TUN2SOCKS_IP"
    ip route add default via \$TUN2SOCKS_IP dev "\$BRIDGE_INTERFACE" table 100 || true
  else
    echo "Маршрут уже существует: default via \$TUN2SOCKS_IP"
  fi

# Настройка NAT
  echo "Проверяем и настраиваем NAT для \$BRIDGE_INTERFACE"
  if ! iptables -t nat -C POSTROUTING -o "\$BRIDGE_INTERFACE" -j MASQUERADE 2>/dev/null; then
    echo "Добавляем NAT для $BRIDGE_INTERFACE"
    iptables -t nat -A POSTROUTING -o "\$BRIDGE_INTERFACE" -j MASQUERADE
  else
    echo "NAT уже настроен для \$BRIDGE_INTERFACE"
  fi

# Настройка FORWARD
  echo "Проверяем и добавляем правило FORWARD для входящего трафика на \$BRIDGE_INTERFACE"
  if ! iptables -C FORWARD -i "\$BRIDGE_INTERFACE" -j ACCEPT 2>/dev/null; then
    echo "Добавляем правило FORWARD для входящего трафика на \$BRIDGE_INTERFACE"
    iptables -A FORWARD -i "\$BRIDGE_INTERFACE" -j ACCEPT
  else
    echo "Правило FORWARD для входящего трафика на \$BRIDGE_INTERFACE уже существует"
  fi

  echo "Проверяем и добавляем правило FORWARD для исходящего трафика с \$BRIDGE_INTERFACE"
  if ! iptables -C FORWARD -o "\$BRIDGE_INTERFACE" -j ACCEPT 2>/dev/null; then
    echo "Добавляем правило FORWARD для исходящего трафика с \$BRIDGE_INTERFACE"
    iptables -A FORWARD -o "\$BRIDGE_INTERFACE" -j ACCEPT
  else
    echo "Правило FORWARD для исходящего трафика с \$BRIDGE_INTERFACE уже существует"
  fi

  echo "Проверяем и добавляем правило FORWARD для исходящего трафика из \$NETWORK"
  if ! iptables -C FORWARD -s \$NETWORK -j ACCEPT 2>/dev/null; then
    echo "Добавляем правило FORWARD для исходящего трафика из /$NETWORK"
    iptables -I FORWARD 1 -s \$NETWORK -j ACCEPT
  else
    echo "Правило FORWARD для исходящего трафика из \$NETWORK уже существует"
  fi

  echo "Проверяем и добавляем правило FORWARD для входящего трафика в \$NETWORK"
  if ! iptables -C FORWARD -d \$NETWORK -j ACCEPT 2>/dev/null; then
    echo "Добавляем правило FORWARD для входящего трафика в \$NETWORK"
    iptables -I FORWARD 1 -d \$NETWORK -j ACCEPT
  else
    echo "Правило FORWARD для входящего трафика в \$NETWORK уже существует"
  fi

    
else
    echo "Интерфейс \$BRIDGE_INTERFACE не найден"
fi
exit 0
EOF

# Завершение работы скрипта
echo "Настройка завершена. Убедитесь, что все маршруты и правила применены корректно."
exit 0


