#!/usr/bin/env bash
# ============================================================================
#  tg-ip-watchdog.sh — поддерживает рабочим доступ к Telegram Bot API из РФ
#                      БЕЗ VPN и без прокси.
#
#  Задача.
#    DNS во всём мире отдаёт api.telegram.org -> 149.154.166.110.
#    Из российских сетей этот адрес не отвечает (TCP/443 отфильтрован).
#    При этом часть адресов Telegram остаётся доступной напрямую.
#
#  Что делает скрипт.
#    1. Проверяет адрес, прибитый сейчас в .env (TELEGRAM_API_IP).
#    2. Если он жив — молча выходит.
#    3. Если умер — ищет новый живой адрес: сначала «горячий список»,
#       затем скан известных подсетей Telegram.
#    4. Найдя — прописывает в .env и перезапускает Gateway.
#    5. Не найдя — громко пишет в лог и подсказывает про план Б (прокси).
#
#  Токен бота скрипту НЕ НУЖЕН: живой Bot API опознаётся по ответу-отпечатку
#  на заведомо неверный токен ({"ok":false,"error_code":401,...}).
#
#  Запускать по таймеру: см. scripts/install-watchdog.sh
# ============================================================================
set -uo pipefail

STAND_DIR="${STAND_DIR:-/opt/openclaw-stand}"
ENV_FILE="$STAND_DIR/openclaw/.env"
COMPOSE_DIR="$STAND_DIR/openclaw"
LOG_FILE="${LOG_FILE:-$STAND_DIR/watchdog.log}"

# Адреса, которые уже видели живыми, — проверяются первыми
HOT_LIST="149.154.167.220 149.154.167.221 149.154.167.222 149.154.166.110 91.108.56.130"
# Подсети Telegram для полного перебора, если горячий список не помог
SCAN_NETS="149.154.167 149.154.166 149.154.165 149.154.164 149.154.175 91.108.56 91.108.4"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }

# Живой ли Bot API по этому адресу.
# Настоящий Bot API на неверный токен отвечает JSON с error_code 401.
# Заглушка провайдера или чужой сервер так не ответит.
is_alive() {
  local ip="$1"
  curl -s --max-time 6 \
       --resolve "api.telegram.org:443:$ip" \
       "https://api.telegram.org/bot123456:INVALID/getMe" 2>/dev/null \
    | grep -q '"error_code":401'
}

# Быстрая проверка TCP/443 без установки TLS — отсеивает отфильтрованные адреса
tcp_open() {
  timeout 2 bash -c "cat < /dev/null > /dev/tcp/$1/443" 2>/dev/null
}

find_alive_ip() {
  local ip
  for ip in $HOT_LIST; do
    is_alive "$ip" && { echo "$ip"; return 0; }
  done

  log "Горячий список пуст, сканирую подсети Telegram..."
  local net i found
  for net in $SCAN_NETS; do
    found=$(
      for i in $(seq 1 254); do
        ( tcp_open "$net.$i" && echo "$net.$i" ) &
        while [ "$(jobs -rp | wc -l)" -ge 60 ]; do wait -n 2>/dev/null || true; done
      done
      wait
    )
    for ip in $(echo "$found" | grep -E '^[0-9]'); do
      is_alive "$ip" && { echo "$ip"; return 0; }
    done
  done
  return 1
}

current_ip() {
  grep -E '^TELEGRAM_API_IP=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d ' \r'
}

main() {
  [ -f "$ENV_FILE" ] || { log "ОШИБКА: не найден $ENV_FILE"; exit 1; }

  local cur; cur="$(current_ip)"

  if [ -n "$cur" ] && is_alive "$cur"; then
    log "OK: $cur жив, ничего не делаю"
    exit 0
  fi

  log "ВНИМАНИЕ: адрес '$cur' больше не отвечает. Ищу замену."

  local new
  if ! new="$(find_alive_ip)"; then
    log "ПРОВАЛ: живых адресов Telegram из этой сети не найдено."
    log "        Включите план Б — прокси: scripts/proxy-fallback/README.md"
    exit 2
  fi

  log "НАЙДЕН живой адрес: $new — переключаюсь"
  # BSD/GNU-safe правка через временный файл
  sed -i.bak -E "s#^TELEGRAM_API_IP=.*#TELEGRAM_API_IP=$new#" "$ENV_FILE"
  grep -qE '^TELEGRAM_API_IP=' "$ENV_FILE" || echo "TELEGRAM_API_IP=$new" >> "$ENV_FILE"

  # extra_hosts применяется только при пересоздании контейнера
  ( cd "$COMPOSE_DIR" && docker compose up -d --force-recreate openclaw-gateway ) >>"$LOG_FILE" 2>&1 \
    && log "Gateway перезапущен с новым адресом $new" \
    || { log "ОШИБКА перезапуска Gateway"; exit 3; }
}

main "$@"
