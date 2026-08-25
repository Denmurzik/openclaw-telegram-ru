#!/usr/bin/env bash
# Поднимает выходной tinyproxy на зарубежном сервере.
# Использование: ./setup-remote-proxy.sh <ssh-алиас> <IP-московского-VPS>
set -euo pipefail

REMOTE="${1:?укажите ssh-алиас зарубежного сервера}"
ALLOW_IP="${2:?укажите публичный IP московского VPS (кому разрешить)}"
PORT="${PROXY_PORT:-8118}"

echo "==> Ставлю tinyproxy на '$REMOTE', доступ только с $ALLOW_IP"

ssh "$REMOTE" bash -s <<REMOTE_SCRIPT
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq tinyproxy >/dev/null

cat > /etc/tinyproxy/tinyproxy.conf <<CONF
User tinyproxy
Group tinyproxy
Port $PORT
Timeout 600
LogLevel Warning
PidFile "/run/tinyproxy/tinyproxy.pid"
MaxClients 50

# ТОЛЬКО московский VPS. Открытый прокси найдут сканеры за сутки.
Allow $ALLOW_IP

ConnectPort 443
ConnectPort 563
DisableViaHeader Yes
CONF

systemctl enable tinyproxy >/dev/null 2>&1 || true
systemctl restart tinyproxy
sleep 1
systemctl is-active tinyproxy
REMOTE_SCRIPT

REMOTE_IP=$(ssh "$REMOTE" "curl -s --max-time 10 https://ipinfo.io/ip")

echo
echo "Готово. Выходной прокси: $REMOTE_IP:$PORT"
echo
echo "Допишите в /opt/openclaw-stand/openclaw/.env на московском VPS:"
echo "  UPSTREAM_PROXY=$REMOTE_IP:$PORT"
echo "  OPENCLAW_PROXY_URL=http://tg-proxy:8888"
