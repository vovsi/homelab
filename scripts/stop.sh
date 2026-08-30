#!/usr/bin/env bash
# ==========================================================================
#  Остановка Immich.
#  В режиме ssd после остановки контейнеров безопасно извлекает внешний диск.
#  Флаг --no-eject — остановить, но диск не извлекать.
# ==========================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

NO_EJECT=0
[[ "${1:-}" == "--no-eject" ]] && NO_EJECT=1

load_env
resolve_storage
require_docker

c_ylw "🛑 Останавливаю Immich ..."
dc down --remove-orphans || die "Не удалось остановить контейнеры"
c_grn "✅ Контейнеры остановлены"

# ------------------------------------------------------ безопасное извлечение
if [[ "${STORAGE_TYPE}" == "ssd" && ${NO_EJECT} -eq 0 ]]; then
  VOL="$(ssd_volume_path)"

  if ! mount | grep -q " on ${VOL} "; then
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
    notify "Immich остановлен" "SSD извлечён — можно отключать кабель"
  else
    BUSY="$(lsof +D "${VOL}" 2>/dev/null | awk 'NR>1 {print $1}' | sort -u | tr '\n' ' ')"
    c_red "❌ Не удалось извлечь диск."
    [[ -n "${BUSY}" ]] && c_red "   Диск занят процессами: ${BUSY}"
    notify "Immich остановлен" "SSD извлечь не удалось: диск занят" "Basso"
    exit 1
  fi
else
  notify "Immich остановлен" "Контейнеры выключены"
fi
