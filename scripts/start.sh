#!/usr/bin/env bash
# ==========================================================================
#  Запуск Immich.
#  - проверяет .env и режим хранилища
#  - для ssd: ждёт монтирования диска (после втыкания кабеля это не мгновенно)
#  - поднимает Docker Desktop, если он ещё не запущен
#  - создаёт структуру директорий, поднимает стек, шлёт уведомление
#
#  Флаг --if-ssd-present: тихий режим для watcher (не ругается, если диск
#  не подключён — просто ничего не делает).
# ==========================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

QUIET_IF_ABSENT=0
[[ "${1:-}" == "--if-ssd-present" ]] && QUIET_IF_ABSENT=1

load_env
resolve_storage

# ------------------------------------------------------- проверка носителя
if [[ "${STORAGE_TYPE}" == "ssd" ]]; then
  VOL="$(ssd_volume_path)"
  # Ждём: при автозапуске по событию том может быть ещё в процессе монтирования
  if ! wait_for_volume "${VOL}" "${VOLUME_WAIT_TIMEOUT:-30}"; then
    if [[ ${QUIET_IF_ABSENT} -eq 1 ]]; then
      c_dim "Диск '${VOL}' не смонтирован — старт пропущен."
      exit 0
    fi
    die "Внешний диск '${VOL}' не подключён. Подсоедини его и повтори запуск (или переключи STORAGE_TYPE=local в .env)."
  fi
  volume_responsive "${VOL}" "${VOLUME_IO_TIMEOUT:-15}" \
    || die "Диск '${VOL}' смонтирован, но не отвечает на чтение. Переподключи кабель (лучше напрямую в Mac, без хаба) и проверь: diskutil list external"
  c_grn "✅ Диск найден: ${VOL}"
else
  c_grn "✅ Режим local: ${STORAGE_ROOT}"
fi

ensure_docker

# Ручная пауза снимается любым явным стартом
rm -f "${PAUSE_FILE}" 2>/dev/null || true

# ------------------------------------------------------- создание структуры
for dir in "${UPLOAD_LOCATION}" "${DB_BACKUP_DIR}"; do
  if [[ ! -d "${dir}" ]]; then
    mkdir -p "${dir}" || die "Не удалось создать директорию: ${dir}"
    c_dim "  создана: ${dir}"
  fi
done

[[ -w "${STORAGE_ROOT}" ]] || die "Нет прав на запись в ${STORAGE_ROOT}"

# --------------------------------------------------------------- запуск
c_ylw "🚀 Поднимаю Immich (${STORAGE_TYPE}) ..."
dc up -d --remove-orphans || die "docker compose up завершился с ошибкой. Логи: make logs"

# ------------------------------------------------ ожидание готовности API
PORT="${IMMICH_PORT:-2283}"
c_dim "Жду готовности http://localhost:${PORT} ..."
READY=0
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 "http://localhost:${PORT}/api/server/ping" >/dev/null 2>&1; then
    READY=1; break
  fi
  sleep 2
done

IP="$(lan_ip)"
if [[ ${READY} -eq 1 ]]; then
  c_grn "✅ Immich готов"
  echo "   Локально : http://localhost:${PORT}"
  echo "   С iPhone : http://${IP}:${PORT}"
  echo "   Данные   : ${STORAGE_ROOT}"
  notify "Immich запущен" "http://${IP}:${PORT} · хранилище: ${STORAGE_TYPE}"
else
  c_ylw "⚠️  Контейнеры подняты, но API ещё не отвечает (первый запуск может занять пару минут)."
  notify "Immich стартует" "API пока не отвечает. Проверь: make logs"
fi
