# CLAUDE.md — контекст проекта для LLM

Локальный медиасервер Immich на macOS с гибридным хранилищем
(диск Mac ↔ внешний SSD) и автоматизациями macOS.

## Стек

- **Immich** — официальные образы `ghcr.io/immich-app/*`, тег `release`.
  Собственных Dockerfile нет и быть не должно: обновление = `docker compose pull`.
- **Docker Compose v2** — один `docker-compose.yml`, project name `immich`.
- **Bash** — вся логика в `scripts/`, общие функции в `scripts/lib.sh`.
- **macOS** — `osascript` (уведомления), `launchd` (слежение за `/Volumes`),
  `diskutil` (извлечение диска), Automator Quick Actions (горячие клавиши).
- **Make** — единая точка входа, цели тонкие, логики не содержат.

Сервисы: `immich-server`, `immich-machine-learning`, `redis` (valkey),
`database` (postgres с vectorchord/pgvecto.rs). Typesense из Immich удалён —
не добавлять.

## Структура

```
.env.example              шаблон конфигурации (в git; .env — нет)
docker-compose.yml        стек, все значения через ${...}
Makefile                  make start/stop/restart/update/install/doctor/...
scripts/lib.sh            общие функции, source во всех скриптах
scripts/start.sh          валидация → создание директорий → up -d → уведомление
scripts/stop.sh           down → sync → diskutil eject (только STORAGE_TYPE=ssd)
scripts/update.sh         pull → up -d → prune → уведомление с версией
scripts/install-automations.sh  LaunchAgent + .app + Quick Actions (+ --uninstall)
```

## Ключевая механика: пути хранилища

`UPLOAD_LOCATION` **не берётся из `.env` напрямую**. `resolve_storage()` в
`lib.sh` выбирает корень по `STORAGE_TYPE` (`LOCAL_STORAGE_PATH` или
`SSD_STORAGE_PATH`) и экспортирует:

```
STORAGE_ROOT     = <выбранный путь>
UPLOAD_LOCATION  = $STORAGE_ROOT/library
DB_VOLUME        = immich_db_local | immich_db_ssd
DB_BACKUP_DIR    = $STORAGE_ROOT/db-backup
```

### Почему БД в именованном томе, а не на диске

PostgreSQL **не работает на bind-mount в Docker Desktop на macOS**: VirtioFS не
сохраняет `chown`, initdb отрабатывает, но postmaster падает с
`data directory "..." has wrong ownership`, post-bootstrap пропускается и база
`immich` не создаётся (сервер потом крутится в рестарте с `3D000`).
Проверено на этом проекте — не пытаться вернуть bind-mount для `database`.

Имя тома привязано к `STORAGE_TYPE`, поэтому у `local` и `ssd` независимые базы,
каждая согласована со своей библиотекой. Перенос между режимами — только дампом:
`make backup-db` → `make restore-db FILE=...`.

Переменные окружения имеют приоритет над `.env` при интерполяции Compose —
на этом всё и держится. Значения в `.env` — только фолбэк для прямого вызова
`docker compose` без скриптов.

**Следствие:** любой новый скрипт или make-цель, дёргающая `docker compose`,
обязана сначала сделать `load_env; resolve_storage`, иначе тома примонтируются
не туда. В Makefile для этого есть `$(call DC,...)`.

## Правила валидации `.env`

`load_env()` падает с понятным сообщением, если:

- файла `.env` нет → подсказка `cp .env.example .env`;
- не задан `STORAGE_TYPE`, `DB_PASSWORD`, `DB_USERNAME`, `DB_DATABASE_NAME`;
- `STORAGE_TYPE` не `local` и не `ssd`.

`resolve_storage()` дополнительно требует абсолютный путь (`/...`).
`start.sh` проверяет монтирование тома и права на запись.

Все ошибки идут через `die()` — красный вывод + уведомление macOS + `exit 1`.
Не заменять на голый `echo`/`exit`.

## Особенности macOS

- Пути в Docker — только абсолютные, `~` не раскрывается. Тильда в `.env` = баг.
- Том определяется через `mount | grep " on /Volumes/ИМЯ "`, а не `[ -d ]`:
  директория `/Volumes/ИМЯ` может остаться после отключения диска.
- Перед `diskutil eject` обязательны `docker compose down` + `sync` — иначе
  «Resource busy». Диагностика занятости — `lsof +D`.
- LaunchAgent использует `WatchPaths: /Volumes`. Событие приходит и на
  монтирование, и на размонтирование, поэтому watcher сам решает,
  поднимать стек или гасить. `ThrottleInterval` защищает от дребезга.
- Горячие клавиши Quick Actions регистрируются через
  `defaults write pbs NSServicesStatus` + `pbs -flush`. Это best-effort:
  на части систем требуется ручное включение в Системных настройках.
  Не делать эту часть блокирующей.
- Уведомления — `osascript -e 'display notification ...'`, всегда с `|| true`.

## Правила разработки

1. **Никакой ручной сборки.** Не добавлять `build:` в compose. Любое изменение
   применяется через `make restart`, обновление — через `make update`.
2. **Конфигурация только в `.env`.** Хардкод путей, портов и лимитов в скриптах
   и compose запрещён — использовать `${VAR:-default}`.
3. **Легковесность по умолчанию.** У каждого сервиса есть
   `deploy.resources.limits`. Новый сервис без лимитов не добавлять.
   Concurrency фоновых джобов Immich живёт в БД (Админка → Задачи), а не в env —
   не пытаться прокинуть его переменной.
4. **Все скрипты** начинаются с `source .../lib.sh` (там `set -euo pipefail`),
   поддерживают запуск из любой директории (`PROJECT_DIR`), сообщают об успехе
   и об ошибке уведомлением.
5. **БД переносится только дампом.** `make backup-db` кладёт `pg_dumpall | gzip`
   в `$STORAGE_ROOT/db-backup`. Копирование каталога тома руками не поддерживается.
6. **Секреты не коммитить.** `.env`, `library/`, `postgres/` — в `.gitignore`.
   Пароль в `.env.example` — заведомо публичный, README требует `make secret`.
7. **Смена `DB_PASSWORD` после инициализации** ломает БД: пароль зашит в том
   `postgres/`. Менять только до первого `make start` или с пересозданием тома.

## Команды

```bash
make start          # запуск (валидация + up -d + уведомление)
make stop           # остановка (+ eject SSD)
make restart        # применить .env / compose
make update         # pull свежих образов + перезапуск
make install        # автоматизации macOS
make uninstall      # снять автоматизации
make doctor         # диагностика окружения и путей
make backup-db      # дамп БД в $STORAGE_ROOT/db-backup
make restore-db FILE=...  # восстановление БД из дампа
make logs / ps / status
make secret         # новый пароль БД
```

Проверка после правок:

```bash
bash -n scripts/*.sh
bash -c 'source scripts/lib.sh; load_env; resolve_storage; dc config'
```
