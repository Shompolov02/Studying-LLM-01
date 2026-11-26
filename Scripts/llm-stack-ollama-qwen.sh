#!/usr/bin/env bash
#
# install.sh — автоматическая установка Ollama из локального архива
# и импорт локальной GGUF-модели Qwen.
#
# Структура папки:
#   llm-stack-ollama-qwen/
#   ├── install.sh
#   ├── ollama-linux-amd64.tar.zst
#   └── qwen2.5-3b-instruct-q4_k_m.gguf
#
set -euo pipefail

# ---------- Настройки ----------
MODEL_NAME="my-qwen"                                  # имя модели в ollama
MODEL_FILE="qwen2.5-3b-instruct-q4_k_m.gguf"          # файл модели
OLLAMA_ARCHIVE="ollama-linux-amd64.tar.zst"           # архив ollama
OLLAMA_USER="ollama"
OLLAMA_HOME="/usr/share/ollama"

# Директория, где лежит сам скрипт (и куда мы положим Modelfile)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Проверки ----------
if [[ $EUID -ne 0 ]]; then
    echo "Запустите скрипт через sudo: sudo ./install.sh"
    exit 1
fi

for f in "$OLLAMA_ARCHIVE" "$MODEL_FILE"; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
        echo "ОШИБКА: не найден файл '$f' рядом со скриптом."
        exit 1
    fi
done

echo "==> [1/6] Установка zstd (если нужно)"
if ! command -v zstd >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y zstd
fi

echo "==> [2/6] Распаковка Ollama в /usr"
tar --zstd -xvf "$SCRIPT_DIR/$OLLAMA_ARCHIVE" -C /usr

echo "==> [3/6] Создание системного пользователя $OLLAMA_USER"
if ! id -u "$OLLAMA_USER" >/dev/null 2>&1; then
    useradd -r -s /bin/false -U -m -d "$OLLAMA_HOME" "$OLLAMA_USER"
else
    echo "    пользователь $OLLAMA_USER уже существует — пропускаем"
fi

# Добавляем вызывающего пользователя в группу ollama,
# чтобы он мог работать с моделью без sudo.
REAL_USER="${SUDO_USER:-}"
if [[ -n "$REAL_USER" ]]; then
    usermod -a -G "$OLLAMA_USER" "$REAL_USER"
    echo "    пользователь $REAL_USER добавлен в группу $OLLAMA_USER"
fi

echo "==> [4/6] Создание systemd-сервиса"
cat > /etc/systemd/system/ollama.service <<'EOF'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="OLLAMA_MODELS=/usr/share/ollama/.ollama/models"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ollama

echo "    ждём запуск сервиса..."
for i in {1..15}; do
    if systemctl is-active --quiet ollama; then break; fi
    sleep 1
done
if ! systemctl is-active --quiet ollama; then
    echo "ОШИБКА: сервис ollama не запустился. Смотрите: journalctl -u ollama -e"
    exit 1
fi

echo "==> [5/6] Регистрация модели '$MODEL_NAME'"
# Modelfile кладём рядом с моделью и указываем абсолютный путь —
# так ollama create сработает независимо от текущей директории.
cat > "$SCRIPT_DIR/Modelfile" <<EOF
FROM $SCRIPT_DIR/$MODEL_FILE
EOF

# Выполняем от имени root — у него есть доступ к файлу и сокету сервиса.
ollama create "$MODEL_NAME" -f "$SCRIPT_DIR/Modelfile"

echo "==> [6/6] Готово. Проверка:"
ollama list

cat <<EOF

✅ Установка завершена.

Запустить чат:        ollama run $MODEL_NAME
Список моделей:       ollama list
Статус сервиса:       systemctl status ollama
Логи:                 journalctl -u ollama -e

⚠️  Если вы добавлялись в группу '$OLLAMA_USER' впервые —
    перелогиньтесь (или выполните: newgrp $OLLAMA_USER),
    чтобы изменения групп вступили в силу.
EOF