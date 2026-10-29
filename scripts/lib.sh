#!/usr/bin/env bash
# ==========================================================================
#  Общие функции для всех скриптов проекта.
#  Подключается через: source "$(dirname "$0")/lib.sh"
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"

# Состояние автоматизаций (watcher, ручная пауза). Переживает перезагрузку.
STATE_DIR="${HOME}/Library/Application Support/immich-homelab"
PAUSE_FILE="${STATE_DIR}/paused"
MOUNT_STATE_FILE="${STATE_DIR}/last-mount-state"
LOCK_DIR="${TMPDIR:-/tmp}/immich-homelab.lock"

# ------------------------------------------------------------------ вывод
c_red()  { printf '\033[0;31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[0;33m%s\033[0m\n' "$*"; }
c_dim()  { printf '\033[0;90m%s\033[0m\n' "$*"; }

# notify "Заголовок" "Текст"  — всплывающее уведомление macOS
notify() {
  local title="$1" msg="$2" sound="${3:-Glass}"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\" sound name \"${sound}\"" >/dev/null 2>&1 || true
  fi
}

# die "Текст" — уведомление + красный вывод + выход с кодом 1
die() {
  local msg="$1"
  c_red "❌ ${msg}"
  notify "Immich — ошибка" "${msg}" "Basso"
  exit 1
}

# ------------------------------------------------------- загрузка .env
load_env() {
  [[ -f "${ENV_FILE}" ]] || die "Файл .env не найден. Выполни: cp .env.example .env"

  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a

  : "${STORAGE_TYPE:?В .env не задан STORAGE_TYPE (local|ssd)}"
  : "${DB_PASSWORD:?В .env не задан DB_PASSWORD}"
  : "${DB_USERNAME:?В .env не задан DB_USERNAME}"
  : "${DB_DATABASE_NAME:?В .env не задан DB_DATABASE_NAME}"

  case "${STORAGE_TYPE}" in
    local|ssd) ;;
    *) die "STORAGE_TYPE='${STORAGE_TYPE}' недопустим. Разрешено: local или ssd." ;;
  esac
}

# ----------------------------------------------- вычисление путей хранилища
# Экспортирует STORAGE_ROOT, UPLOAD_LOCATION, DB_VOLUME, DB_BACKUP_DIR.
# Переменные окружения имеют приоритет над .env при интерполяции в compose.
resolve_storage() {
  if [[ "${STORAGE_TYPE}" == "ssd" ]]; then
    : "${SSD_STORAGE_PATH:?В .env не задан SSD_STORAGE_PATH}"
    STORAGE_ROOT="${SSD_STORAGE_PATH}"
  else
    : "${LOCAL_STORAGE_PATH:?В .env не задан LOCAL_STORAGE_PATH}"
    STORAGE_ROOT="${LOCAL_STORAGE_PATH}"
  fi

  [[ "${STORAGE_ROOT}" == /* ]] || die "Путь хранилища должен быть абсолютным: ${STORAGE_ROOT}"

  export STORAGE_ROOT
  export UPLOAD_LOCATION="${STORAGE_ROOT}/library"

  # Данные PostgreSQL живут в ИМЕНОВАННОМ томе Docker, а не на bind-mount:
  # в Docker Desktop на macOS (VirtioFS) postgres не стартует на bind-mount
  # с ошибкой "data directory has wrong ownership".
  # Имя тома привязано к STORAGE_TYPE => у local и ssd независимые базы,
  # каждая согласована со своей библиотекой.
  export DB_VOLUME="immich_db_${STORAGE_TYPE}"

  # Куда make backup-db кладёт дампы БД (рядом с библиотекой)
  export DB_BACKUP_DIR="${STORAGE_ROOT}/db-backup"
}

# Имя тома внешнего диска: из SSD_VOLUME_NAME или из первого компонента пути
ssd_volume_path() {
  if [[ -n "${SSD_VOLUME_NAME:-}" ]]; then
    printf '/Volumes/%s' "${SSD_VOLUME_NAME}"
  else
    # /Volumes/External/ImmichData -> /Volumes/External
    printf '%s' "$(printf '%s' "${SSD_STORAGE_PATH}" | awk -F/ '{print "/"$2"/"$3}')"
  fi
}

# ------------------------------------------------------------------- том
# Проверяем именно монтирование: директория /Volumes/ИМЯ может остаться
# висеть после отключения диска.
volume_mounted() {
  local vol="${1:-$(ssd_volume_path)}"
  mount | grep -q " on ${vol} "
}

# Том может быть в mount-таблице, но не отвечать на I/O (отвалился по шине,
# залип драйвер). Обычный ls по такому тому висит вечно — проверяем с таймаутом.
# volume_responsive <путь> [секунд]
volume_responsive() {
  local vol="$1" timeout="${2:-10}" pid i rc
  ls "${vol}" >/dev/null 2>&1 &
  pid=$!
  for ((i = 0; i < timeout * 2; i++)); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      wait "${pid}" && return 0 || return 1
    fi
    sleep 0.5
  done
  kill -9 "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  return 1
}

# Ждёт монтирования тома. wait_for_volume <путь> [секунд]
wait_for_volume() {
  local vol="$1" timeout="${2:-30}" i
  for ((i = 0; i < timeout; i++)); do
    volume_mounted "${vol}" && return 0
    sleep 1
  done
  return 1
}

# ------------------------------------------------------------------ docker
require_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker не установлен. Поставь Docker Desktop или OrbStack."
  docker info >/dev/null 2>&1 || die "Docker не запущен. Открой Docker Desktop / OrbStack и повтори."
}

# Поднимает Docker Desktop, если он не запущен, и ждёт готовности демона.
# ensure_docker [секунд]
ensure_docker() {
  local timeout="${1:-${DOCKER_WAIT_TIMEOUT:-180}}" i
  command -v docker >/dev/null 2>&1 || die "Docker не установлен. Поставь Docker Desktop."
  docker info >/dev/null 2>&1 && return 0

  c_dim "Docker не запущен — открываю Docker Desktop ..."
  open -ga Docker >/dev/null 2>&1 || die "Не удалось запустить Docker Desktop (нет /Applications/Docker.app?)"

  for ((i = 0; i < timeout; i++)); do
    if docker info >/dev/null 2>&1; then
      c_grn "✅ Docker готов"
      return 0
    fi
    sleep 1
  done
  die "Docker Desktop не поднялся за ${timeout} с"
}

dc() { docker compose --project-directory "${PROJECT_DIR}" "$@"; }

# Есть ли поднятые контейнеры проекта
stack_running() {
  [[ -n "$(dc ps --quiet --status running 2>/dev/null)" ]]
}

# ------------------------------------------------------------------- lock
# Защита от параллельных запусков (watcher дёргается на каждое событие
# в /Volumes). with_lock [сколько секунд ждать], 0 = не ждать.
with_lock() {
  local wait_sec="${1:-0}" waited=0
  while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
    # Протухший лок (процесс убит) снимаем сами
    if [[ -n "$(find "${LOCK_DIR}" -maxdepth 0 -mmin +15 2>/dev/null)" ]]; then
      rm -rf "${LOCK_DIR}"
      continue
    fi
    (( waited >= wait_sec )) && return 1
    waited=$((waited + 1))
    sleep 1
  done
  trap 'rm -rf "${LOCK_DIR}"' EXIT INT TERM
  return 0
}

# ------------------------------------------------------------------ бэкап
# Дамп БД в $DB_BACKUP_DIR + ротация. Печатает путь к файлу.
# Требует поднятого стека и доступного хранилища.
backup_db() {
  local keep="${DB_BACKUP_KEEP:-7}" file
  mkdir -p "${DB_BACKUP_DIR}" || return 1
  file="${DB_BACKUP_DIR}/immich-$(date +%Y%m%d-%H%M%S).sql.gz"

  if ! dc exec -T database pg_dumpall --clean --if-exists -U "${DB_USERNAME}" 2>/dev/null | gzip > "${file}"; then
    rm -f "${file}"
    return 1
  fi
  # Пустой/битый дамп не считаем бэкапом
  [[ -s "${file}" ]] || { rm -f "${file}"; return 1; }

  # Ротация: оставляем последние ${keep} дампов
  local old
  old="$(ls -1t "${DB_BACKUP_DIR}"/immich-*.sql.gz 2>/dev/null | tail -n "+$((keep + 1))" || true)"
  [[ -n "${old}" ]] && printf '%s\n' "${old}" | xargs rm -f || true

  printf '%s' "${file}"
}

lan_ip() {
  local ip
  for iface in en0 en1 en2; do
    ip="$(ipconfig getifaddr "${iface}" 2>/dev/null || true)"
    [[ -n "${ip}" ]] && { printf '%s' "${ip}"; return; }
  done
  printf 'localhost'
}
