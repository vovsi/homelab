#!/usr/bin/env bash
# ==========================================================================
#  Обновление до актуальной версии Immich.
#  Тянет свежие образы и перезапускает стек. Пересборка не требуется —
#  используются официальные готовые контейнеры.
# ==========================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_env
resolve_storage
require_docker

if [[ "${STORAGE_TYPE}" == "ssd" ]]; then
  VOL="$(ssd_volume_path)"
  mount | grep -q " on ${VOL} " || die "Для обновления подключи SSD '${VOL}' (библиотека лежит на нём)."
fi

BEFORE="$(dc images --quiet 2>/dev/null | sort | md5 || true)"

c_ylw "⬇️  Тяну свежие образы ..."
dc pull || die "Не удалось скачать образы (проверь интернет)"

c_ylw "♻️  Перезапускаю сервисы ..."
dc up -d --remove-orphans || die "Не удалось перезапустить стек"

c_ylw "🧹 Чищу устаревшие образы ..."
docker image prune -f >/dev/null 2>&1 || true

AFTER="$(dc images --quiet 2>/dev/null | sort | md5 || true)"
VERSION="$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' \
            "ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}" 2>/dev/null || true)"
[[ -z "${VERSION}" || "${VERSION}" == "<no value>" ]] && VERSION="${IMMICH_VERSION:-release}"

if [[ "${BEFORE}" == "${AFTER}" ]]; then
  c_grn "✅ Уже актуальная версия: ${VERSION}"
  notify "Immich" "Обновлений нет — версия ${VERSION}"
else
  c_grn "✅ Обновлено до ${VERSION}"
  notify "Immich обновлён" "Актуальная версия: ${VERSION}"
fi

echo "   Веб: http://$(lan_ip):${IMMICH_PORT:-2283}"
