#!/usr/bin/env bash
# ==========================================================================
#  Общие функции для всех скриптов проекта.
#  Подключается через: source "$(dirname "$0")/lib.sh"
# ==========================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"

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

# Имя тома SSD: из SSD_VOLUME_NAME или из первого компонента SSD_STORAGE_PATH
ssd_volume_path() {
  if [[ -n "${SSD_VOLUME_NAME:-}" ]]; then
    printf '/Volumes/%s' "${SSD_VOLUME_NAME}"
  else
    # /Volumes/MySSD/ImmichData -> /Volumes/MySSD
    printf '%s' "$(printf '%s' "${SSD_STORAGE_PATH}" | awk -F/ '{print "/"$2"/"$3}')"
  fi
}

# ------------------------------------------------------------------ docker
require_docker() {
  command -v docker >/dev/null 2>&1 || die "Docker не установлен. Поставь Docker Desktop или OrbStack."
  docker info >/dev/null 2>&1 || die "Docker не запущен. Открой Docker Desktop / OrbStack и повтори."
}

dc() { docker compose --project-directory "${PROJECT_DIR}" "$@"; }

# Есть ли поднятые контейнеры проекта
stack_running() {
  [[ -n "$(dc ps --quiet --status running 2>/dev/null)" ]]
}

lan_ip() {
  local ip
  for iface in en0 en1 en2; do
    ip="$(ipconfig getifaddr "${iface}" 2>/dev/null || true)"
    [[ -n "${ip}" ]] && { printf '%s' "${ip}"; return; }
  done
  printf 'localhost'
}
