#!/usr/bin/env bash
# ==========================================================================
#  Первоначальная настройка автоматизаций macOS.
#
#  Устанавливает:
#   1. LaunchAgent, следящий за /Volumes — при подключении SSD автоматически
#      поднимает Immich, при отключении корректно гасит контейнеры.
#   2. Два приложения в ~/Applications ("Immich Start", "Immich Stop") —
#      запуск в один клик из Spotlight / Dock / Быстрых команд.
#   3. Quick Actions (Службы) с горячими клавишами:
#        ⌃⌥⌘I — старт
#        ⌃⌥⌘O — стоп + безопасное извлечение SSD
#
#  Удаление всего установленного:  ./scripts/install-automations.sh --uninstall
# ==========================================================================

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

AGENT_LABEL="com.homelab.immich.volumewatch"
AGENT_PLIST="${HOME}/Library/LaunchAgents/${AGENT_LABEL}.plist"
SUPPORT_DIR="${HOME}/Library/Application Support/immich-homelab"
WATCHER="${SUPPORT_DIR}/volume-watch.sh"
APPS_DIR="${HOME}/Applications"
SERVICES_DIR="${HOME}/Library/Services"
START_APP="${APPS_DIR}/Immich Start.app"
STOP_APP="${APPS_DIR}/Immich Stop.app"
START_WF="${SERVICES_DIR}/Immich Start.workflow"
STOP_WF="${SERVICES_DIR}/Immich Stop.workflow"

# ==========================================================================
#  Удаление
# ==========================================================================
uninstall_all() {
  c_ylw "Удаляю автоматизации ..."
  launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
  rm -f "${AGENT_PLIST}"
  rm -rf "${SUPPORT_DIR}" "${START_APP}" "${STOP_APP}" "${START_WF}" "${STOP_WF}"
  defaults delete pbs NSServicesStatus 2>/dev/null || true
  /System/Library/CoreServices/pbs -flush 2>/dev/null || true
  c_grn "✅ Все автоматизации удалены"
  exit 0
}
[[ "${1:-}" == "--uninstall" ]] && uninstall_all

load_env
resolve_storage

# ==========================================================================
#  1. Watcher + LaunchAgent на /Volumes
# ==========================================================================
install_agent() {
  mkdir -p "${SUPPORT_DIR}" "${HOME}/Library/LaunchAgents"

  cat > "${WATCHER}" <<WEOF
#!/usr/bin/env bash
# Автогенерируется scripts/install-automations.sh — правки будут перезаписаны.
# Срабатывает при любом изменении в /Volumes (подключение/отключение диска).
PROJECT_DIR="${PROJECT_DIR}"
source "\${PROJECT_DIR}/scripts/lib.sh"
load_env
resolve_storage

# В режиме local автоподхват диска не нужен
[[ "\${STORAGE_TYPE}" == "ssd" ]] || exit 0

VOL="\$(ssd_volume_path)"
command -v docker >/dev/null 2>&1 || exit 0
docker info >/dev/null 2>&1 || exit 0

if mount | grep -q " on \${VOL} "; then
  # Диск на месте — поднимаем, если ещё не подняты
  stack_running || "\${PROJECT_DIR}/scripts/start.sh" --if-ssd-present
else
  # Диск исчез — гасим контейнеры, чтобы не писать в пустоту
  if stack_running; then
    dc down --remove-orphans >/dev/null 2>&1 || true
    notify "Immich остановлен" "Внешний диск отключён"
  fi
fi
WEOF
  chmod +x "${WATCHER}"

  cat > "${AGENT_PLIST}" <<PEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${AGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${WATCHER}</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>/Volumes</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>15</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${SUPPORT_DIR}/watch.log</string>
    <key>StandardErrorPath</key>
    <string>${SUPPORT_DIR}/watch.err.log</string>
</dict>
</plist>
PEOF

  plutil -lint "${AGENT_PLIST}" >/dev/null || die "Некорректный plist LaunchAgent"
  launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "${AGENT_PLIST}" 2>/dev/null \
    || launchctl load -w "${AGENT_PLIST}" 2>/dev/null \
    || c_ylw "⚠️  LaunchAgent не удалось загрузить автоматически (загрузится после перелогина)"

  c_grn "✅ LaunchAgent установлен — Immich стартует сам при подключении SSD"
}

# ==========================================================================
#  2. Приложения в один клик (Spotlight / Dock / Быстрые команды)
# ==========================================================================
install_apps() {
  command -v osacompile >/dev/null 2>&1 || { c_ylw "⚠️  osacompile недоступен — приложения не созданы"; return; }
  mkdir -p "${APPS_DIR}"

  rm -rf "${START_APP}" "${STOP_APP}"
  osacompile -o "${START_APP}" \
    -e "do shell script \"/bin/zsh -lc \\\"'${PROJECT_DIR}/scripts/start.sh'\\\" > /dev/null 2>&1 &\"" \
    2>/dev/null || c_ylw "⚠️  Не удалось создать Immich Start.app"
  osacompile -o "${STOP_APP}" \
    -e "do shell script \"/bin/zsh -lc \\\"'${PROJECT_DIR}/scripts/stop.sh'\\\" > /dev/null 2>&1 &\"" \
    2>/dev/null || c_ylw "⚠️  Не удалось создать Immich Stop.app"

  [[ -d "${START_APP}" ]] && c_grn "✅ Приложения созданы: ~/Applications/Immich Start.app, Immich Stop.app"
}

# ==========================================================================
#  3. Quick Actions (Службы) + горячие клавиши
# ==========================================================================
# make_workflow <путь к .workflow> <имя службы> <команда>
make_workflow() {
  local wf="$1" name="$2" cmd="$3"
  rm -rf "${wf}"
  mkdir -p "${wf}/Contents"

  cat > "${wf}/Contents/Info.plist" <<IEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>${name}</string>
            </dict>
            <key>NSMessage</key>
            <string>runWorkflowAsService</string>
            <key>NSRequiredContext</key>
            <dict>
                <key>NSApplicationIdentifier</key>
                <string>com.apple.finder</string>
            </dict>
        </dict>
    </array>
</dict>
</plist>
IEOF

  cat > "${wf}/Contents/document.wflow" <<WFEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AMApplicationBuild</key><string>521</string>
    <key>AMApplicationVersion</key><string>2.10</string>
    <key>AMDocumentVersion</key><string>2</string>
    <key>actions</key>
    <array>
        <dict>
            <key>action</key>
            <dict>
                <key>AMAccepts</key>
                <dict>
                    <key>Container</key><string>List</string>
                    <key>Optional</key><true/>
                    <key>Types</key><array><string>com.apple.cocoa.string</string></array>
                </dict>
                <key>AMActionVersion</key><string>2.0.3</string>
                <key>AMApplication</key><array><string>Automator</string></array>
                <key>AMParameterProperties</key>
                <dict>
                    <key>COMMAND_STRING</key><dict/>
                    <key>CheckedForUserDefaultShell</key><dict/>
                    <key>inputMethod</key><dict/>
                    <key>shell</key><dict/>
                    <key>source</key><dict/>
                </dict>
                <key>AMProvides</key>
                <dict>
                    <key>Container</key><string>List</string>
                    <key>Types</key><array><string>com.apple.cocoa.string</string></array>
                </dict>
                <key>ActionBundlePath</key><string>/System/Library/Automator/Run Shell Script.action</string>
                <key>ActionName</key><string>Run Shell Script</string>
                <key>ActionParameters</key>
                <dict>
                    <key>COMMAND_STRING</key><string>${cmd}</string>
                    <key>CheckedForUserDefaultShell</key><true/>
                    <key>inputMethod</key><integer>0</integer>
                    <key>shell</key><string>/bin/zsh</string>
                    <key>source</key><string></string>
                </dict>
                <key>BundleIdentifier</key><string>com.apple.RunShellScript</string>
                <key>CFBundleVersion</key><string>2.0.3</string>
                <key>CanShowSelectedItemsWhenRun</key><false/>
                <key>CanShowWhenRun</key><true/>
                <key>Category</key><array><string>AMCategoryUtilities</string></array>
                <key>Class Name</key><string>RunShellScriptAction</string>
                <key>InputUUID</key><string>2E7C9F10-0001-4A00-9000-000000000001</string>
                <key>OutputUUID</key><string>2E7C9F10-0002-4A00-9000-000000000002</string>
                <key>UUID</key><string>2E7C9F10-0003-4A00-9000-000000000003</string>
                <key>UnlocalizedApplications</key><array><string>Automator</string></array>
                <key>arguments</key><dict/>
                <key>isViewVisible</key><integer>1</integer>
                <key>location</key><string>309.000000:253.000000</string>
                <key>nibPath</key><string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
            </dict>
            <key>isViewVisible</key><integer>1</integer>
        </dict>
    </array>
    <key>connectors</key><dict/>
    <key>workflowMetaData</key>
    <dict>
        <key>applicationBundleIDsByPath</key><dict/>
        <key>applicationPaths</key><array/>
        <key>inputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
        <key>outputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
        <key>presentationMode</key><integer>15</integer>
        <key>processesInput</key><integer>0</integer>
        <key>serviceInputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
        <key>serviceOutputTypeIdentifier</key><string>com.apple.Automator.nothing</string>
        <key>serviceProcessesInput</key><integer>0</integer>
        <key>systemImageName</key><string>NSActionTemplate</string>
        <key>useAutomaticInputType</key><integer>0</integer>
        <key>workflowTypeIdentifier</key><string>com.apple.Automator.servicesMenu</string>
    </dict>
</dict>
</plist>
WFEOF

  plutil -lint "${wf}/Contents/Info.plist" >/dev/null 2>&1 || return 1
  plutil -lint "${wf}/Contents/document.wflow" >/dev/null 2>&1 || return 1
}

install_quick_actions() {
  mkdir -p "${SERVICES_DIR}"

  make_workflow "${START_WF}" "Immich Start" "'${PROJECT_DIR}/scripts/start.sh'" \
    || { c_ylw "⚠️  Quick Action 'Immich Start' создать не удалось"; return; }
  make_workflow "${STOP_WF}" "Immich Stop" "'${PROJECT_DIR}/scripts/stop.sh'" \
    || { c_ylw "⚠️  Quick Action 'Immich Stop' создать не удалось"; return; }

  # Горячие клавиши: ⌃⌥⌘I / ⌃⌥⌘O  (@ = cmd, ~ = option, ^ = control)
  defaults write pbs NSServicesStatus -dict-add \
    "(null) - Immich Start - runWorkflowAsService" \
    '{ "key_equivalent" = "@~^i"; "enabled_services_menu" = 1; "enabled_context_menu" = 1; }' 2>/dev/null || true
  defaults write pbs NSServicesStatus -dict-add \
    "(null) - Immich Stop - runWorkflowAsService" \
    '{ "key_equivalent" = "@~^o"; "enabled_services_menu" = 1; "enabled_context_menu" = 1; }' 2>/dev/null || true

  /System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
  /System/Library/CoreServices/pbs -flush  >/dev/null 2>&1 || true

  c_grn "✅ Quick Actions установлены: ⌃⌥⌘I — старт, ⌃⌥⌘O — стоп"
}

# ==========================================================================
#  Выполнение
# ==========================================================================
c_ylw "⚙️  Настраиваю автоматизации macOS для ${PROJECT_DIR}"
echo

install_agent
install_apps
install_quick_actions

echo
c_grn "Готово."
cat <<TXT

Что дальше:
  • Горячие клавиши работают из Finder. Если не сработали сразу —
    Системные настройки → Клавиатура → Сочетания клавиш → Службы:
    включи «Immich Start» / «Immich Stop» (иногда нужен перелогин).
  • Приложения ~/Applications/Immich Start.app и Immich Stop.app можно
    перетащить в Dock или добавить в приложение «Быстрые команды»
    (действие «Открыть приложение») и назначить там свою комбинацию.
  • Автозапуск при подключении SSD работает только при STORAGE_TYPE=ssd.
    Лог слежения: ${SUPPORT_DIR}/watch.log

Удалить всё:  ./scripts/install-automations.sh --uninstall
TXT

notify "Immich" "Автоматизации macOS установлены"
