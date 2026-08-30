# Immich Home Media Server — единая точка входа.
# Все цели — тонкие обёртки над scripts/*.sh.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Выполнить команду docker compose с корректно вычисленными путями из .env
define DC
	@bash -c 'source scripts/lib.sh; load_env; resolve_storage; dc $(1)'
endef

.PHONY: help start stop restart update logs ps status install uninstall doctor shell-db prune secret backup-db restore-db

help: ## Показать список команд
	@echo "Immich Home Media Server"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

start: ## Запустить сервер
	@./scripts/start.sh

stop: ## Остановить сервер (+ извлечь SSD в режиме ssd)
	@./scripts/stop.sh

restart: ## Применить изменения .env / docker-compose.yml
	@./scripts/stop.sh --no-eject && ./scripts/start.sh

update: ## Обновить Immich до последней версии
	@./scripts/update.sh

install: ## Установить автоматизации macOS (автозапуск, горячие клавиши)
	@./scripts/install-automations.sh

uninstall: ## Удалить автоматизации macOS
	@./scripts/install-automations.sh --uninstall

logs: ## Живые логи всех сервисов
	$(call DC,logs -f --tail=100)

ps: ## Состояние контейнеров
	$(call DC,ps)

status: ## Потребление CPU / RAM контейнерами
	@docker stats --no-stream $$(docker ps --filter "name=immich_" --format "{{.Names}}") 2>/dev/null || echo "Контейнеры не запущены"

shell-db: ## Консоль psql внутри контейнера БД
	$(call DC,exec database psql -U $$$$DB_USERNAME -d $$$$DB_DATABASE_NAME)

doctor: ## Проверить окружение и .env
	@bash -c 'source scripts/lib.sh; load_env; resolve_storage; require_docker; \
		echo "STORAGE_TYPE     : $$STORAGE_TYPE"; \
		echo "UPLOAD_LOCATION  : $$UPLOAD_LOCATION"; \
		echo "Том БД           : $$DB_VOLUME"; \
		echo "Бэкапы БД        : $$DB_BACKUP_DIR"; \
		echo "Порт             : $${IMMICH_PORT:-2283}"; \
		echo "LAN-адрес        : http://$$(lan_ip):$${IMMICH_PORT:-2283}"; \
		if [[ "$$STORAGE_TYPE" == "ssd" ]]; then \
			v=$$(ssd_volume_path); \
			mount | grep -q " on $$v " && echo "SSD              : смонтирован ($$v)" || echo "SSD              : НЕ подключён ($$v)"; \
		fi; \
		[[ -d "$$UPLOAD_LOCATION" ]] && echo "Библиотека       : существует" || echo "Библиотека       : будет создана при старте"; \
		echo "Docker           : ок"'

prune: ## Удалить неиспользуемые образы Docker
	@docker image prune -f

secret: ## Сгенерировать новый пароль БД (перед первым запуском)
	@openssl rand -base64 24 | tr -d '/+=' | cut -c1-28

backup-db: ## Дамп БД в <хранилище>/db-backup (делать регулярно!)
	@bash -c 'source scripts/lib.sh; load_env; resolve_storage; require_docker; \
		mkdir -p "$$DB_BACKUP_DIR"; \
		f="$$DB_BACKUP_DIR/immich-$$(date +%Y%m%d-%H%M%S).sql.gz"; \
		dc exec -T database pg_dumpall --clean --if-exists -U "$$DB_USERNAME" | gzip > "$$f"; \
		echo "✅ $$f ($$(du -h "$$f" | cut -f1))"'

restore-db: ## Восстановить БД из дампа: make restore-db FILE=путь.sql.gz
	@test -n "$(FILE)" || { echo "Укажи файл: make restore-db FILE=.../immich-….sql.gz"; exit 1; }
	@bash -c 'source scripts/lib.sh; load_env; resolve_storage; require_docker; \
		gunzip -c "$(FILE)" | dc exec -T database psql -U "$$DB_USERNAME" -d postgres; \
		echo "✅ Восстановлено. Перезапусти: make restart"'
