#!/usr/bin/env bash
# ============================================================================
#  deploy.sh — разворачивает стенд OpenClaw с нуля на чистой Ubuntu.
#
#  Проверено на: Ubuntu 24.04, 1 vCPU, 2 ГБ RAM, Docker 29.x.
#  Запускать от root на сервере, который будет держать Gateway.
#
#  Перед запуском: скопировать .env.example в .env и заполнить секреты.
# ============================================================================
set -euo pipefail

STAND="${STAND:-/opt/openclaw-stand}"
REPO_URL="https://github.com/openclaw/openclaw.git"
IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Swap.
#    На боксе с 2 ГБ RAM Node-процесс Gateway способен упереться в потолок и
#    получить OOM-kill — вместе с соседними сервисами. Swap это предотвращает.
# ---------------------------------------------------------------------------
say "Swap"
if swapon --show | grep -q .; then
  echo "swap уже есть, пропускаю"
else
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10
  echo "создан swap 2 ГБ"
fi

# ---------------------------------------------------------------------------
# 2. Исходники апстрима — нужен только штатный docker-compose.yml.
#    Наши правки лежат отдельно, в docker-compose.override.yml.
# ---------------------------------------------------------------------------
say "Репозиторий openclaw"
mkdir -p "$STAND"
if [ -d "$STAND/openclaw/.git" ]; then
  git -C "$STAND/openclaw" pull --ff-only
else
  git clone --depth 1 "$REPO_URL" "$STAND/openclaw"
fi

say "Образ $IMAGE"
docker pull "$IMAGE"

# ---------------------------------------------------------------------------
# 3. Каталоги состояния.
#    Набор подкаталогов повторяет то, что делает штатный scripts/docker/setup.sh.
# ---------------------------------------------------------------------------
say "Каталоги состояния"
mkdir -p "$STAND"/data/config/{identity,agents/main/agent,agents/main/sessions}
mkdir -p "$STAND"/data/{workspace,auth-secrets}

# ---------------------------------------------------------------------------
# 4. Конфиг и SOUL.md.
# ---------------------------------------------------------------------------
say "Конфигурация"
cp "$STAND/config/openclaw.json" "$STAND/data/config/openclaw.json"
cp "$STAND/config/SOUL.md"       "$STAND/data/workspace/SOUL.md"

# ---------------------------------------------------------------------------
# 5. ВАЖНО: владелец каталогов.
#    Процесс внутри контейнера работает под node (uid=1000). Каталоги,
#    созданные root, для него недоступны, и Gateway падает в бесконечный
#    рестарт с EACCES на mkdir '/home/node/.openclaw/state'.
#    Ошибка неочевидная: контейнер выглядит "запущенным", но health не встаёт.
# ---------------------------------------------------------------------------
say "Права (uid 1000 = node внутри контейнера)"
chown -R 1000:1000 "$STAND/data"

# ---------------------------------------------------------------------------
# 6. Оверлей рядом со штатным compose — Docker Compose подхватит его сам.
# ---------------------------------------------------------------------------
say "Оверлей compose и .env"
ln -sf "$STAND/docker-compose.override.yml" "$STAND/openclaw/docker-compose.override.yml"
if [ ! -f "$STAND/openclaw/.env" ]; then
  echo "ОШИБКА: нет $STAND/openclaw/.env — скопируйте .env.example и заполните." >&2
  exit 1
fi
chmod 600 "$STAND/openclaw/.env"

# ---------------------------------------------------------------------------
# 7. Старт.
# ---------------------------------------------------------------------------
say "Запуск Gateway"
cd "$STAND/openclaw"
docker compose up -d --no-build openclaw-gateway

echo "жду готовности..."
for i in $(seq 1 30); do
  if curl -fsS --max-time 5 http://127.0.0.1:18789/readyz >/dev/null 2>&1; then
    echo "Gateway готов"; break
  fi
  sleep 3
done

# ---------------------------------------------------------------------------
# 8. Watchdog живого адреса Telegram (Этап 2).
# ---------------------------------------------------------------------------
say "Watchdog Telegram"
bash "$STAND/scripts/install-watchdog.sh"

say "Проверка"
docker compose ps
docker compose run -T --rm openclaw-cli channels status --probe || true

cat <<'DONE'

Готово.

Проверить агента:
  docker compose run -T --rm openclaw-cli agent --agent main -m "Привет"

Открыть Control UI с ноутбука (порт наружу НЕ смотрит):
  ssh -L 18789:127.0.0.1:18789 <хост>
  затем http://127.0.0.1:18789/
DONE
