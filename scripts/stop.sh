#!/usr/bin/env bash
# ==========================================================================
#  Остановка Immich.
#  Перед остановкой снимает дамп БД на диск (БД живёт в томе Docker, а не
#  на диске — без дампа диск сам по себе галерею не восстановит).
#  В режиме ssd после остановки контейнеров безопасно извлекает внешний диск.
#  Флаг --no-eject — остановить, но диск не извлекать (ставит паузу: watcher
#  не будет поднимать стек заново, пока диск не переподключат).
#  Флаг --no-backup — пропустить дамп БД.
# ==========================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

NO_EJECT=0
NO_BACKUP=0
for arg in "$@"; do
  case "${arg}" in
    --no-eject)  NO_EJECT=1 ;;
    --no-backup) NO_BACKUP=1 ;;
  esac
done

load_env
resolve_storage
require_docker

# --------------------------------------------------------- дамп БД на диск
if [[ ${NO_BACKUP} -eq 0 ]] && stack_running && [[ -d "${STORAGE_ROOT}" ]]; then
  c_dim "Снимаю дамп БД ..."
  if FILE="$(backup_db)"; then
    c_grn "✅ Бэкап БД: ${FILE}"
  else
    c_ylw "⚠️  Дамп БД не удался — останавливаю без бэкапа"
  fi
fi

c_ylw "🛑 Останавливаю Immich ..."
dc down --remove-orphans || die "Не удалось остановить контейнеры"
c_grn "✅ Контейнеры остановлены"

# Остановка без извлечения — это ручная пауза: watcher не должен
# поднимать стек обратно, пока диск не переподключат.
if [[ ${NO_EJECT} -eq 1 ]]; then
  mkdir -p "${STATE_DIR}" 2>/dev/null || true
  : > "${PAUSE_FILE}" 2>/dev/null || true
fi

# ------------------------------------------------------ безопасное извлечение
if [[ "${STORAGE_TYPE}" == "ssd" && ${NO_EJECT} -eq 0 ]]; then
  VOL="$(ssd_volume_path)"

  if ! volume_mounted "${VOL}"; then
    c_dim "Диск ${VOL} уже не смонтирован."
    notify "Immich остановлен" "Контейнеры выключены"
    exit 0
  fi

  # Сбрасываем кэш записи и ждём, пока Docker отпустит файлы
  c_dim "Сбрасываю буферы записи ..."
  sync; sleep 2

  c_ylw "⏏️  Извлекаю ${VOL} ..."
  if diskutil eject "${VOL}" >/dev/null 2>&1; then
    c_grn "✅ Диск безопасно извлечён — можно отсоединять кабель"
    notify "Immich остановлен" "Диск извлечён — можно отключать кабель"
  else
    BUSY="$(lsof +D "${VOL}" 2>/dev/null | awk 'NR>1 {print $1}' | sort -u | tr '\n' ' ')"
    c_red "❌ Не удалось извлечь диск."
    [[ -n "${BUSY}" ]] && c_red "   Диск занят процессами: ${BUSY}"
    notify "Immich остановлен" "Диск извлечь не удалось: занят" "Basso"
    exit 1
  fi
else
  notify "Immich остановлен" "Контейнеры выключены"
fi
