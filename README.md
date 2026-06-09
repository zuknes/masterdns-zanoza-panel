<div align="right">

**🇷🇺 Русский** · [🇬🇧 English](README.en.md)

</div>

# masterdns-zanoza-panel

Веб-панель и менеджер процессов для [MasterDnsVPN](https://github.com/masterking32/MasterDnsVPN) с поддержкой приложения [Zanoza (iOS)](https://github.com/palmbeachpete9/masterdns-zanoza-ios).

Панель позволяет администратору создавать «инстансы» (комбинации **домен + ключ шифрования**) и раздавать их пользователям: каждый инстанс виден как `домен + ключ` и копируется как ссылка `zanoza://` для импорта в приложение Zanoza.

---

![Панель — список инстансов](docs/dashboard.png)

![Создание инстанса](docs/create-instance.png)

![Вход в панель](docs/login.png)

---

## Установка

### Контейнер (рекомендуется) — любой Linux с Docker или Podman

```sh
# Установщик сам определит Docker или Podman и установит нужное.
# Запустите одной командой:
curl -fsSL https://raw.githubusercontent.com/zuknes/masterdns-zanoza-panel/feature/docker-installer/scripts/container-install.sh | sudo bash
```

**Что под капотом:**

- **Docker** — используется если уже установлен (compose-файл). На Debian 12 устанавливается автоматически.
- **Podman ≥4.4 + Quadlet** — используется если Docker отсутствует. Нативный для RHEL 9+, Ubuntu 24.04+. Контейнер управляется как systemd-сервис.
- **Podman <4.4** — fallback через `podman generate systemd`. Установщик предложит выбор.

Установщик проведёт вас по шагам:

1. **Контейнерный рантайм** — автоопределение, при необходимости установка
2. **Порт 53** — проверит и предложит освободить (отключит `DNSStubListener` у systemd-resolved)
3. **Оптимизации ядра** — спросит, применить ли sysctl-тюнинг для высокой нагрузки DNS (по умолчанию — да). Настройки пишутся в `/etc/sysctl.d/99-zanoza-docker.conf` и легко убираются: `sudo rm /etc/sysctl.d/99-zanoza-docker.conf && sudo sysctl --system`
4. **Логин/пароль** — авто-генерация (10 + 20 символов) или ввод вручную
5. **Сертификат**:
   - **1) Self-signed IP-сертификат** — на 6 дней, авто-продление внутри контейнера (crond)
   - **2) Let's Encrypt** — нужна A-запись `panel.example.com` → IP сервера
   - **3) Без TLS** — панель слушает только `127.0.0.1` (доступ через nginx/SSH-туннель)

Панель работает в `network_mode: host`, контейнер не нужно публиковать порты. Авто-рестарт включён.

**SELinux** — на системах с SELinux enforcing (RHEL, Rocky, Alma) к volume-маунтам автоматически добавляется флаг `:Z`. На системах без SELinux флаг игнорируется.

После установки доступна CLI-команда `zanoza`:

```sh
zanoza              # интерактивное меню управления (требует sudo)
sudo zanoza restart  # перезапустить панель
sudo zanoza logs     # просмотр логов
sudo zanoza update   # обновить (git pull + пересборка)
sudo zanoza uninstall # удалить панель
```

Конфигурация панели — редактируйте `.env` и перезапускайте через `zanoza restart`. Учётные данные хранятся в `zanoza-config/panel.env` (хэшированы).

Для локальных переопределений Docker (например, другой `restart` policy или дополнительные volume) создайте `docker-compose.override.yml` — он автоматически подхватывается Docker Compose и находится в `.gitignore`.

### Legacy — bare-metal (Ubuntu / Debian)

```sh
curl -fsSL https://raw.githubusercontent.com/zuknes/masterdns-zanoza-panel/feature/docker-installer/scripts/install.sh | sudo bash
```

Установщик устанавливает Go, собирает бинарники из исходников, ставит systemd-сервис, CLI-команду `zanoza`.

> **Примечание:** Docker-версия проще, не требует Go toolchain, изолирует панель и работает на любом дистрибутиве Linux.

## Модель инстансов (домены + ключи)

Сервер MasterDnsVPN — это один процесс, слушающий **UDP :53**, с **одним** ключом и **одним** доменов. Чтобы раздавать пользователям **разные ключи**, панель использует форк сервера с **keyring** (`keyring.json`), который выбирает ключ(и) **по домену запроса** (домен виден до расшифровки):

- **Один ключ на домен** → прямая расшифровка, подходит **любой** метод, включая **XOR** (самый быстрый).
- **Несколько ключей на одном домене** → сервер перебирает ключи кольца; требуется **AEAD** (ChaCha20 / AES-GCM), потому что только AEAD позволяет отличить верный ключ по тегу аутентификации. Перебор идёт только на входящих пакетах этого домена; «горячий» ключ продвигается в начало кольца.

Метод шифрования инстанса должен **совпадать** с методом в приложении Zanoza (ссылка `zanoza://` задаёт его автоматически).

> **Важно!** Все домены инстансов (`v.example1.com`, `v.example2.com`, …) должны быть делегированы, и иметь:<br>
>**A-запись**, указывающую на IP адрес сервера с панелью<br>
>**NS-запись**, указывающую на A-запись.

## Структура репозитория

```
masterdns-zanoza-panel/
├── src/main.tsx                  # React-интерфейс (Vite + Tailwind + lucide)
├── index.html, vite.config.ts, tailwind.config.ts, package.json
├── cmd/zanoza-panel/             # Go-бэкенд панели (stdlib)
│   ├── main.go                   #   HTTP/TLS, роутинг, API, embed web/dist
│   ├── config.go, auth.go        #   конфиг + авторизация (cookie/basic)
│   ├── process.go                #   супервизор сервера MasterDnsVPN + keyring.json
│   ├── zanozalink.go             #   генерация ссылок zanoza://
│   └── web/dist/                 #   собранный фронтенд (встроен в бинарь)
├── masterdns/                    # форк сервера MasterDnsVPN
│   └── internal/keyring/         #   покеольцевой выбор ключей по домену
├── scripts/
│   ├── container-install.sh      #   установщик (Docker или Podman, любой Linux)
│   ├── zanoza                    #   универсальная CLI-команда управления
│   ├── zanoza-common.sh          #   общие хелперы (сертификаты, acme.sh, SELinux)
│   └── install.sh                #   установщик bare-metal (Ubuntu/Debian)
├── Dockerfile                    #   OCI-образ (Alpine, из исходников)
├── docker-compose.yml            #   Docker Compose (network_mode: host)
├── docker-entrypoint.sh          #   entrypoint: config.json, crond для авто-renew
├── docker-renew-cert.sh          #   перевыпуск self-signed сертификата (crond)
└── packaging/systemd/zanoza-panel.service
```

## Переменные окружения

Все переменные опциональны; панель работает без них с дефолтными значениями.

| Переменная | Назначение | По умолчанию |
|---|---|---|
| `ZANOZA_CONFIG` | Путь к JSON-конфигу панели | `/etc/zanoza-panel/config.json` |
| `ZANOZA_RUNTIME_DIR` | Директория для keyring.json и server_config.toml | `<configDir>/masterdns` |
| `ZANOZA_PANEL_ADDR` | IP-адрес для HTTP-сервера | из `config.json` |
| `ZANOZA_PANEL_PORT` | Порт панели (1–65535) | из `config.json` |
| `ZANOZA_PANEL_PATH` | URL-путь админки (например `/secret`) | из `config.json` |
| `ZANOZA_TLS_CERT` / `ZANOZA_TLS_KEY` | Пути к TLS-сертификату и ключу | из `config.json` |
| `ZANOZA_NAME` | Имя сервера (отображается в UI) | из `config.json` |
| `ZANOZA_USER` / `ZANOZA_PASSWORD` | Авто-создание админа при первом запуске | — (только при первой настройке) |
| `ZANOZA_MASTERDNS_BIN` | Путь к бинарнику MasterDnsVPN | `/usr/local/bin/masterdns-server` |
| `ZANOZA_DNS_HOST` | UDP-адрес DNS-сервера | `0.0.0.0` |
| `ZANOZA_DNS_PORT` | UDP-порт DNS-сервера (1–65535) | `53` |
| `ZANOZA_DNS_UPSTREAM` | JSON-массив upstream-резолверов | `["1.1.1.1:53", "1.0.0.1:53"]` |

В Docker-версии переменные задаются в файле `.env` (копируется из `.env.example` при установке).

## Сборка из исходников

```sh
# инструменты (один раз)
go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest
go install mvdan.cc/gofumpt@latest

# фронтенд (нужен node)
npm install && npm run build

# всё через Makefile
make fmt      # форматирование gofumpt
make lint     # golangci-lint
make test     # тесты с -race
make build    # собрать бинарники
make check    # всё сразу (CI)
```

## Благодарности

- Протокол и сервер: [MasterDnsVPN от MasterkinG32](https://github.com/masterking32/MasterDnsVPN)
- UI и структура: [olcrtc-manager-panel](https://github.com/BigDaddy3334/olcrtc-manager-panel)
- Стиль установщика и CLI: [3x-ui](https://github.com/MHSanaei/3x-ui)
- Приложение-клиент: [Zanoza (iOS)](https://github.com/palmbeachpete9/masterdns-zanoza-ios)
