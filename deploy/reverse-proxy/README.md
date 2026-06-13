# Reverse-proxy (обход блокировки РКН)

Прямой хост Supabase (`rhoyopwzdqtcyawiipya.supabase.co`, AWS за Cloudflare) блокируется/троттлится на мобильных сетях РФ (ТСПУ/РКН) — приложение виснет на загрузке. Решение: собственный reverse-proxy на зарубежном VPS с своим доменом и валидным TLS. Клиент ходит на домен прокси, прокси переписывает Host/SNI на хост проекта и форвардит в Supabase.

```
iOS-клиент ──HTTPS──▶ i-goose.pro (Caddy на VPS)
                          │ терминирует TLS (Let's Encrypt)
                          │ переписывает Host + SNI на rhoyopwzdqtcyawiipya.supabase.co
                          ▼
              https://rhoyopwzdqtcyawiipya.supabase.co  (Supabase за Cloudflare)
```

Один домен покрывает всё: auth / rest / realtime (WSS) / storage / functions — клиент выводит все эндпоинты из одного `supabaseURL`.

## Текущий деплой

- **VPS:** AEZA (Амстердам, NL), `178.236.247.115`, Ubuntu 26.04, 1 vCPU / 2 ГБ.
- **Домен:** `i-goose.pro` (REG.RU), A-запись `@ → 178.236.247.115`, TTL 1h.
- **Caddy:** 2.11.x, поставлен из официального apt-репозитория; сервис `caddy` (systemd, enabled).
- **TLS:** Let's Encrypt, авто-выпуск/продление (HTTP-01).
- **Конфиг:** `/etc/caddy/Caddyfile` (копия — рядом в этом каталоге). Access-log: `/var/log/caddy/access.log`.

## Сосуществование с AmneziaVPN (НЕ сломать)

На этом же VPS работает AmneziaWG (контейнер Docker `amnezia-awg2`, **UDP/41324**). Caddy слушает **TCP 80/443** — конфликта нет.

- **НЕ включать `ufw`** — он переписывает iptables и ломает правила Docker (DNAT/MASQUERADE), от которых зависит VPN. Caddy сам по себе iptables не трогает.
- Не трогать контейнер `amnezia-awg2`, интерфейсы `amn0`/`awg0`/`docker0`, порт UDP/41324.
- Проверка живости VPN: `docker exec amnezia-awg2 awg show` (свежие handshake-и у peer-ов).

## Провижн нового VPS (переезд без релиза приложения)

Смена точки входа НЕ требует релиза в App Store: домен(ы) зашиты в `SupabaseConfig.hostCandidates`, переезд = смена A-записи DNS + поднятие Caddy на новом VPS.

1. Направить A-запись домена на IP нового VPS (TTL низкий — применится за ~час).
2. Поставить Caddy:
   ```sh
   apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
   curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
   curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
   apt-get update && apt-get install -y caddy
   ```
3. Положить `Caddyfile` (из этого каталога; при смене домена — поправить имя сайта) в `/etc/caddy/Caddyfile`.
4. Разрешить запись access-log под sandbox systemd:
   ```sh
   mkdir -p /etc/systemd/system/caddy.service.d
   printf '[Service]\nLogsDirectory=caddy\n' > /etc/systemd/system/caddy.service.d/override.conf
   systemctl daemon-reload
   ```
5. `systemctl restart caddy` — TLS выпустится автоматически (нужны открытые входящие 80/443).
6. Проверка: `curl -sS https://<домен>/auth/v1/health` → `401 {"message":"No API key found..."}` (маршрут жив, серт валиден).

### Гоча с access.log

`caddy validate`, запущенный от **root** до первого старта сервиса, создаёт `/var/log/caddy/access.log` владельцем `root:root` → сервис под юзером `caddy` потом не может в него писать (`permission denied`, сервис не стартует). Лечение: `rm -f /var/log/caddy/access.log` и `systemctl restart caddy` (caddy пересоздаст файл от своего юзера). Drop-in `LogsDirectory=caddy` (шаг 4) — обязателен.

## Клиентская часть

`MyMessanger/SupabaseConfig.swift`:
- `hostCandidates` — домен прокси ПЕРВЫМ, прямой хост Supabase последним (fallback). Список зашит в бинарь.
- `rewrittenToCurrentHost(_:)` / `rewrittenURL(fromStored:)` — переписывают host у абсолютных медиа-URL из БД (storage хранит абсолютные ссылки) на текущий хост, чтобы старые ссылки с прямым хостом тоже шли через прокси и были устойчивы к смене VPS.

## TODO (безопасность сервера)

- Отключить вход по SSH-паролю (ключ уже настроен), сменить рутовый пароль.
- `fail2ban` для SSH — только с проверкой, что VPN (iptables/Docker) не задет.
