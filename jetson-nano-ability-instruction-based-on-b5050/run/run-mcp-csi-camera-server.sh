#!/usr/bin/env bash
set -euo pipefail

# run-mcp-csi-camera-server.sh
#
# Wrapper для запуска mcp-csi-camera (MCP-сервер CSI-камеры) через nohup
# с автогенерацией имени log-файла, по аналогии с run-llama-server.sh.
#
# Возможности:
#   - запускает бинарь из ../mcp-csi-camera/target/release/mcp-csi-camera
#     относительно расположения этого скрипта (cwd значения не имеет);
#   - выставляет RUST_LOG=info по умолчанию (можно переопределить, передав
#     RUST_LOG в окружение перед вызовом);
#   - принимает аргументы для mcp-csi-camera после `--` (или просто как
#     позиционные); если аргументов нет — используются продакшн-дефолты:
#       --listen 0.0.0.0:8777
#       --source gstreamer
#       --allowed-host 192.168.178.59
#   - включает аргументы в имя log-файла;
#   - добавляет timestamp старта в имя log-файла;
#   - создаёт рядом .pid файл с PID запущенного процесса;
#   - безопасно нормализует имя файла: заменяет `/`, `:`, пробелы и прочие
#     потенциально проблемные символы на `_`.
#
# Usage:
#   ./run-mcp-csi-camera-server.sh                          # с дефолтами
#   ./run-mcp-csi-camera-server.sh -- --source mock         # переопределить
#   RUST_LOG=debug ./run-mcp-csi-camera-server.sh           # подробнее логи
#
#   ./run-mcp-csi-camera-server.sh -- \
#     --listen 0.0.0.0:8777 \
#     --source gstreamer \
#     --allowed-host 192.168.178.59 \
#     --flip-method 0
#
# Generated files example:
#   mcp-csi-camera-listen_0.0.0.0_8777_source_gstreamer_allowed-host_192.168.178.59-20260503-220015.log
#   mcp-csi-camera-listen_0.0.0.0_8777_source_gstreamer_allowed-host_192.168.178.59-20260503-220015.pid
#
# Notes:
#   - Сам сервер запускается в фоне через nohup.
#   - stdout и stderr перенаправляются в log-файл (в текущей директории).
#   - PID можно использовать для остановки процесса:
#
#       kill "$(cat <generated-file>.pid)"
#
#   - Аргументы передаются в mcp-csi-camera без изменений.
#     Нормализация применяется только к имени log/pid файла.

# Путь к скрипту → путь к бинарнику относительно скрипта,
# чтобы запуск работал из любого cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SCRIPT_DIR/../mcp-csi-camera/target/release/mcp-csi-camera"

# Optional separator.
# Позволяет явно отделить аргументы mcp-csi-camera от позиционных аргументов
# скрипта (на будущее — сейчас позиционных нет, но единый стиль с
# run-llama-server.sh).
if [[ "${1:-}" == "--" ]]; then
  shift
fi

# Дефолтные аргументы — продакшн-сетап на Jetson в LAN.
# Применяются только если пользователь не передал ни одного аргумента.
DEFAULT_ARGS=(
  --listen 0.0.0.0:8777
  --source gstreamer
  --allowed-host 192.168.178.59
)

if [[ $# -eq 0 ]]; then
  ORIGINAL_ARGS=("${DEFAULT_ARGS[@]}")
else
  ORIGINAL_ARGS=("$@")
fi

# sanitize <string>
#
# Преобразует произвольную строку в безопасный фрагмент имени файла:
#   - lowercase;
#   - срезает ведущие дефисы ("--source" → "source");
#   - заменяет всё кроме [a-z0-9._=-] на "_";
#   - схлопывает повторяющиеся "_";
#   - убирает "_" в начале и конце.
sanitize() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's#^-+##; s#[^a-z0-9._=-]+#_#g; s#_+#_#g; s#^_+|_+$##g'
}

# Timestamp старта (YYYYMMDD-HHMMSS).
TS="$(date '+%Y%m%d-%H%M%S')"

# Безопасный фрагмент имени файла из всех аргументов.
ARG_PARTS=()
for arg in "${ORIGINAL_ARGS[@]}"; do
  ARG_PARTS+=("$(sanitize "$arg")")
done
SAFE_ARGS="$(IFS=_; echo "${ARG_PARTS[*]}")"

# Итоговое имя log-файла.
if [[ -n "$SAFE_ARGS" ]]; then
  LOG_FILE="mcp-csi-camera-${SAFE_ARGS}-${TS}.log"
else
  LOG_FILE="mcp-csi-camera-${TS}.log"
fi
PID_FILE="${LOG_FILE%.log}.pid"

# Pre-flight: бинарь должен существовать. Если нет — сразу подсказка как собрать.
if [[ ! -x "$BIN" ]]; then
  echo "binary not found or not executable: $BIN" >&2
  echo "build it first:" >&2
  echo "  cd $SCRIPT_DIR/../mcp-csi-camera && cargo build --release" >&2
  exit 1
fi

# RUST_LOG по умолчанию info; уважаем существующее значение, если задано.
export RUST_LOG="${RUST_LOG:-info}"

# Запуск mcp-csi-camera.
#
# stdout и stderr → "$LOG_FILE"
# процесс отвязан от терминала через nohup и уходит в фон.
nohup "$BIN" "${ORIGINAL_ARGS[@]}" > "$LOG_FILE" 2>&1 &

PID=$!
echo "$PID" > "$PID_FILE"

echo "bin:      $BIN"
echo "args:     ${ORIGINAL_ARGS[*]}"
echo "RUST_LOG: $RUST_LOG"
echo "log:      $LOG_FILE"
echo "pid:      $PID"
echo "pid_file: $PID_FILE"
