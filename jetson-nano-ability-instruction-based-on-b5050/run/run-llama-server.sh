#!/usr/bin/env bash
set -euo pipefail

# run-llama-server.sh
#
# Wrapper для запуска llama-server через nohup с автогенерацией имени log-файла.
#
# Возможности:
#   - принимает Hugging Face model id первым аргументом;
#   - передаёт все аргументы после `--` напрямую в llama-server;
#   - включает HF model id в имя log-файла;
#   - включает аргументы llama-server в имя log-файла;
#   - добавляет timestamp старта в имя log-файла;
#   - создаёт рядом .pid файл с PID запущенного процесса;
#   - безопасно нормализует имя файла: заменяет `/`, `:`, пробелы и прочие
#     потенциально проблемные символы на `_`.
#
# Usage:
#   ./run-llama-server.sh <hf-model> -- <llama-server args...>
#
# Examples:
#   bash ../llama.cpp-b9006/jetson-nano-ability-instruction-based-on-b5050/run/run-llama-server.sh unsloth/Qwen3.5-0.8B-GGUF:Q8_0 -- --n-gpu-layers 99 --port 8776 --host 0.0.0.0 --reasoning-budget 128 --reasoning-budget-message "Time to summarize and answer." --image-max-tokens 529
#   ./run-llama-server.sh unsloth/Qwen3.5-0.8B-GGUF:Q8_0 -- \
#     --n-gpu-layers 99 \
#     --port 8776 \
#     --host 0.0.0.0
#
#   ./run-llama-server.sh ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF -- \
#     --port 8080 \
#     --ctx-size 8192
#
# Generated files example:
#   llama-server-unsloth_qwen3.5-0.8b-gguf_q8_0-n-gpu-layers_99_port_8776_host_0.0.0.0-20260503-142530.log
#   llama-server-unsloth_qwen3.5-0.8b-gguf_q8_0-n-gpu-layers_99_port_8776_host_0.0.0.0-20260503-142530.pid
#
# Notes:
#   - Сам llama-server запускается в фоне через nohup.
#   - stdout и stderr перенаправляются в log-файл.
#   - PID можно использовать для остановки процесса:
#
#       kill "$(cat <generated-file>.pid)"
#
#   - Аргументы передаются в llama-server без изменений.
#     Нормализация применяется только к имени log/pid файла.

HF_MODEL="${1:?Usage: $0 <hf-model> -- <llama-server args...>}"
shift

# Optional separator.
# Позволяет явно отделить HF model id от аргументов llama-server.
#
# Example:
#   ./run-llama-server.sh unsloth/Qwen3.5-0.8B-GGUF:Q8_0 -- --port 8776
#
# После удаления separator-а в "$@" остаются только аргументы llama-server.
if [[ "${1:-}" == "--" ]]; then
  shift
fi

# Сохраняем оригинальные аргументы.
# Именно этот массив будет передан в llama-server без изменений.
ORIGINAL_ARGS=("$@")

# sanitize <string>
#
# Преобразует произвольную строку в безопасный фрагмент имени файла.
#
# Что делает:
#   - приводит строку к lowercase;
#   - убирает ведущие дефисы, чтобы "--port" стал "port";
#   - заменяет все символы кроме [a-z0-9._=-] на "_";
#   - схлопывает повторяющиеся "_";
#   - убирает "_" в начале и конце.
#
# Examples:
#   "unsloth/Qwen3.5-0.8B-GGUF:Q8_0"
#     -> "unsloth_qwen3.5-0.8b-gguf_q8_0"
#
#   "--n-gpu-layers"
#     -> "n-gpu-layers"
#
#   "0.0.0.0"
#     -> "0.0.0.0"
sanitize() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's#^-+##; s#[^a-z0-9._=-]+#_#g; s#_+#_#g; s#^_+|_+$##g'
}

# Timestamp старта.
#
# Format:
#   YYYYMMDD-HHMMSS
#
# Example:
#   20260503-142530
TS="$(date '+%Y%m%d-%H%M%S')"

# Безопасный вариант HF model id для имени файла.
SAFE_MODEL="$(sanitize "$HF_MODEL")"

# Собираем безопасный фрагмент имени файла из аргументов llama-server.
#
# Example input args:
#   --n-gpu-layers 99 --port 8776 --host 0.0.0.0
#
# Example SAFE_ARGS:
#   n-gpu-layers_99_port_8776_host_0.0.0.0
ARG_PARTS=()
for arg in "${ORIGINAL_ARGS[@]}"; do
  ARG_PARTS+=("$(sanitize "$arg")")
done

SAFE_ARGS="$(IFS=_; echo "${ARG_PARTS[*]}")"

# Итоговое имя log-файла.
#
# Без аргументов:
#   llama-server-<safe-model>-<timestamp>.log
#
# С аргументами:
#   llama-server-<safe-model>-<safe-args>-<timestamp>.log
if [[ -n "$SAFE_ARGS" ]]; then
  LOG_FILE="llama-server-${SAFE_MODEL}-${SAFE_ARGS}-${TS}.log"
else
  LOG_FILE="llama-server-${SAFE_MODEL}-${TS}.log"
fi

# PID-файл имеет то же имя, что и log-файл, но с расширением .pid.
PID_FILE="${LOG_FILE%.log}.pid"

# Запуск llama-server.
#
# Итоговая команда:
#   nohup rllama-server -hf "$HF_MODEL" "${ORIGINAL_ARGS[@]}" > "$LOG_FILE" 2>&1 &
#
# stdout:
#   пишется в "$LOG_FILE"
#
# stderr:
#   тоже пишется в "$LOG_FILE"
#
# background:
#   процесс запускается в фоне
nohup rllama-server \
  -hf "$HF_MODEL" \
  "${ORIGINAL_ARGS[@]}" \
  > "$LOG_FILE" 2>&1 &

# PID последнего background-процесса.
PID=$!

# Сохраняем PID рядом с логом.
echo "$PID" > "$PID_FILE"

echo "log: $LOG_FILE"
echo "pid: $PID"
echo "pid_file: $PID_FILE"
