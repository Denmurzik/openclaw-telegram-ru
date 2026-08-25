# План Б: точечный прокси для Telegram

Основное решение стенда — прямое подключение к живому адресу Telegram
(см. корневой README, раздел «Этап 2»). Прокси **выключен** и здесь лежит
на случай, если Роскомнадзор закроет все прямые адреса Bot API и
`tg-ip-watchdog.sh` перестанет находить живой.

Признак, что пора включать план Б — в `watchdog.log`:

```
ПРОВАЛ: живых адресов Telegram из этой сети не найдено.
```

## Идея

Через заграницу пускаем **только `api.telegram.org`**. Трафик к LLM
(`api.orcarouter.ai`) остаётся прямым из Москвы — он не заблокирован, и
гнать его лишним хопом незачем: это и медленнее, и добавляет точку отказа.

```
   МОСКВА (VPS, без VPN)                    ЗАРУБЕЖНЫЙ СЕРВЕР
 ┌─────────────────────────┐              ┌────────────────────┐
 │ openclaw ──► tinyproxy ─┼── только ───►│ tinyproxy :8118    │──► api.telegram.org
 │              (sidecar)  │  telegram    │ Allow: <IP Москвы> │
 │                    │    │              └────────────────────┘
 │                    └────┼── всё остальное напрямую ─────────►  api.orcarouter.ai
 └─────────────────────────┘
```

Системного VPN на московской машине по-прежнему нет — проксирование живёт
на уровне приложения и касается одного домена.

## Включение

**Шаг 1.** Поднять выходной прокси на зарубежном сервере:

```bash
./setup-remote-proxy.sh <ssh-алиас-зарубежного-сервера> <публичный-IP-московского-VPS>
```

Скрипт ставит tinyproxy, разрешает подключения **только** с указанного IP и
печатает готовую строку для `.env`.

**Шаг 2.** На московском VPS дописать в `openclaw/.env`:

```
UPSTREAM_PROXY=<IP-зарубежного-сервера>:8118
OPENCLAW_PROXY_URL=http://tg-proxy:8888
```

**Шаг 3.** Поднять sidecar и перезапустить Gateway:

```bash
cd /opt/openclaw-stand/openclaw
docker compose -f docker-compose.yml \
               -f docker-compose.override.yml \
               -f /opt/openclaw-stand/scripts/proxy-fallback/docker-compose.proxy.yml \
               up -d
```

**Шаг 4.** Убрать пиннинг IP — он больше не нужен и будет только мешать:
закомментировать `extra_hosts` в `docker-compose.override.yml`.

## Проверка

```bash
# через sidecar: Telegram должен отвечать
docker compose exec openclaw-gateway \
  curl -s -x http://tg-proxy:8888 https://api.telegram.org/bot123:INVALID/getMe
# ожидаем: {"ok":false,"error_code":401,...}

# через sidecar: LLM должен идти НАПРЯМУЮ, ответ покажет московский IP
docker compose exec openclaw-gateway \
  curl -s -x http://tg-proxy:8888 https://ipinfo.io/json | grep country
# ожидаем: "country": "RU"
```

Второй тест — главный: он доказывает, что через заграницу уходит только
Telegram, а не весь трафик стенда.

## Безопасность

Выходной прокси принимает подключения только с одного IP-адреса. Открытый
прокси в интернете за сутки находят сканеры и начинают гонять через него
чужой трафик — поэтому `Allow` обязателен, а не желателен.
