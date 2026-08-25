#!/usr/bin/env bash
# Ставит tg-ip-watchdog.sh на systemd-таймер: проверка каждые 5 минут.
set -euo pipefail
STAND_DIR="${STAND_DIR:-/opt/openclaw-stand}"

cat > /etc/systemd/system/tg-ip-watchdog.service <<UNIT
[Unit]
Description=OpenClaw: поддержание живого IP Telegram Bot API (работа без VPN)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Environment=STAND_DIR=$STAND_DIR
ExecStart=$STAND_DIR/scripts/tg-ip-watchdog.sh
UNIT

cat > /etc/systemd/system/tg-ip-watchdog.timer <<UNIT
[Unit]
Description=Проверка доступности Telegram Bot API каждые 5 минут

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now tg-ip-watchdog.timer
echo "Таймер установлен. Статус:"
systemctl list-timers tg-ip-watchdog.timer --no-pager
