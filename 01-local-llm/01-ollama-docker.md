# Ollama в Docker: развёртывание и работа с моделями

[← К оглавлению репозитория](../README.md)

Инструкция рассчитана на Ubuntu Server 24.04 в VirtualBox: 8 ГБ RAM, 4 vCPU, диск около 60 ГБ. Команды выполняются в терминале **виртуальной машины**, если явно не указано иное. Для доступа к Docker используется `sudo`. В этом варианте вычисления идут на CPU; виртуальная видеокарта VirtualBox сама по себе не предоставляет Ollama GPU для вычислений.

## Содержание

1. [Как устроен стенд](#1-как-устроен-стенд)
2. [Установка Docker](#2-установка-docker)
3. [Запуск Ollama](#3-запуск-ollama)
4. [Установка и переключение моделей](#4-установка-и-переключение-моделей)
5. [Импорт GGUF через хост](#5-импорт-gguf-через-хост)
6. [HTTP API](#6-http-api)
7. [Docker Compose](#7-docker-compose)
8. [Эксплуатация и диагностика](#8-эксплуатация-и-диагностика)
9. [Безопасная очистка](#9-безопасная-очистка)
10. [Самопроверка и шпаргалка](#10-самопроверка-и-шпаргалка)

## 1. Как устроен стенд

```text
Физический компьютер → VirtualBox → Ubuntu Server
                                     │
                           127.0.0.1:11434 (API)
                                     │
                           контейнер llm-ollama
                                     │ /root/.ollama
                           том llm-ollama-data
                                     └─ модели и данные Ollama
```

**Образ** `ollama/ollama` — шаблон с программой; **контейнер** `llm-ollama` — запущенный экземпляр; **том** `llm-ollama-data` — постоянное хранилище; **модель** — отдельно скачанные веса, с которыми работает Ollama. Один сервер обслуживает несколько моделей. Удаление контейнера не удаляет том; удаление тома удаляет модели и другие данные Ollama в нём.

**GGUF** — формат файла модели. Квантование уменьшает размер весов и требования к ресурсам ценой возможной потери качества. Размер файла не равен расходу RAM: дополнительно нужна память для контекста и вычислений. На ВМ с 8 ГБ начните с небольшой модели и наблюдайте за памятью. Импортированный GGUF и модель из реестра могут различаться шаблоном диалога и настройками, даже если основаны на одной архитектуре.

## 2. Установка Docker

Если `sudo docker version` и `sudo docker compose version` работают, переходите к следующему разделу. На новой Ubuntu установите Docker Engine и Compose plugin по [официальной инструкции Docker](https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository): там описаны поддерживаемые версии и проверка конфликтующих пакетов. Не удаляйте существующие пакеты, не проверив, какие сервисы их используют.

Проверка установки:

```bash
sudo systemctl enable --now docker
sudo docker version
sudo docker compose version
sudo docker run --rm hello-world
```

`Hello from Docker!` подтверждает запуск тестового контейнера; образ остаётся на диске. В группе `docker` пользователь получает привилегии, близкие к root, поэтому здесь используем `sudo`.

## 3. Запуск Ollama

Если контейнер `llm-ollama` уже существует, повторно выполнять `docker run` не нужно. Проверьте `sudo docker ps -a`, при необходимости запустите `sudo docker start llm-ollama` и переходите к проверке API.

```bash
sudo docker pull ollama/ollama:latest
sudo docker volume create llm-ollama-data
sudo docker run -d --name llm-ollama \
  --restart unless-stopped \
  -p 127.0.0.1:11434:11434 \
  -v llm-ollama-data:/root/.ollama \
  ollama/ollama:latest
```

`-d` запускает контейнер в фоне; `--restart unless-stopped` задаёт политику перезапуска; `-p` публикует порт только на loopback **ВМ**, а не физического компьютера; `-v` подключает именованный том. `latest` может измениться при следующем скачивании: для воспроизводимости используйте проверенный тег или digest. Официальный пример: [Ollama в Docker](https://docs.ollama.com/docker).

```bash
sudo docker ps
sudo docker logs --tail 30 llm-ollama
sudo docker exec llm-ollama ollama --version
curl -fsS http://127.0.0.1:11434/api/tags
```

При пустом хранилище API вернёт список `models` без моделей. Посмотреть том и его расположение внутри ВМ:

```bash
sudo docker volume inspect llm-ollama-data
sudo docker volume inspect llm-ollama-data --format '{{.Mountpoint}}'
```

Docker управляет содержимым тома; вручную менять его внутренние файлы не нужно. На физическом компьютере данные ВМ обычно находятся внутри её виртуального диска.

## 4. Установка и переключение моделей

Из [каталога Ollama](https://ollama.com/library) выберите модель и точный тег. Например:

```bash
sudo docker exec llm-ollama ollama pull qwen2.5:3b
sudo docker exec llm-ollama ollama pull qwen2.5:1.5b
sudo docker exec llm-ollama ollama list
```

Загрузка 3B занимает примерно 1,9 ГБ, но размер и доступные теги проверяйте в каталоге. Для медленного соединения есть [импорт GGUF](#5-импорт-gguf-через-хост). После загрузки модели сохраняются в томе.

Запустите диалог; `-it` подключает интерактивный терминал:

```bash
sudo docker exec -it llm-ollama ollama run qwen2.5:3b
```

Задайте вопрос, например: «Объясни разницу между контейнером и томом». Для выхода введите `/bye`. Чтобы выбрать другую модель, запустите новую сессию с другим именем:

```bash
sudo docker exec -it llm-ollama ollama run qwen2.5:1.5b
sudo docker exec llm-ollama ollama ps
```

`list` показывает сохранённые модели, `ps` — модели, загруженные в память. После выхода модель может оставаться в RAM некоторое время; данные на диске при этом не удаляются. Остановить загруженную модель можно командой `sudo docker exec llm-ollama ollama stop qwen2.5:3b`. Для удаления конкретной сохранённой модели используйте `sudo docker exec llm-ollama ollama rm qwen2.5:1.5b`; остальные модели остаются, хотя общие данные могут использоваться совместно.

## 5. Импорт GGUF через хост

Если загрузка внутри ВМ идёт слишком медленно, скачайте на физический компьютер **совместимый с Ollama** GGUF из надёжного источника и перенесите его в ВМ через MobaXterm/SFTP или `scp`. Проверьте лицензию и, если издатель предоставляет SHA-256, контрольную сумму на обеих сторонах. Например, в Ubuntu:

```bash
sha256sum ~/llm-import/model.gguf
```

Создайте папку `~/llm-import` в ВМ и положите в неё файл под именем `model.gguf`. Сравните вывод с опубликованной контрольной суммой; копировать файл в контейнер следует только после проверки. На время импорта необходимо место и под исходный файл, и под данные в томе.

```bash
mkdir -p ~/llm-import
ls -lh ~/llm-import/model.gguf
cat > ~/llm-import/Modelfile <<'EOF'
FROM /tmp/llm-import/model.gguf
EOF
sudo docker exec llm-ollama mkdir -p /tmp/llm-import
sudo docker cp ~/llm-import/model.gguf llm-ollama:/tmp/llm-import/model.gguf
sudo docker cp ~/llm-import/Modelfile llm-ollama:/tmp/llm-import/Modelfile
sudo docker exec llm-ollama ollama create my-qwen:gguf -f /tmp/llm-import/Modelfile
sudo docker exec llm-ollama ollama list
sudo docker exec -it llm-ollama ollama run my-qwen:gguf
```

Выйдите через `/bye` и убедитесь, что ответ осмыслен. Имя `my-qwen:gguf` — локальное имя, а не обязательное название исходной модели. После успешной проверки удалите только временную копию **в контейнере**:

```bash
sudo docker exec llm-ollama rm -rf /tmp/llm-import
```

Исходный GGUF в `~/llm-import` остаётся; удалите его отдельно, только если резервная копия больше не нужна. Ollama не квантует GGUF при импорте. Для разбитых GGUF нужны все части; синтаксис и поддерживаемые варианты описаны в [документации импорта](https://docs.ollama.com/import). Если ответы повреждены или импорт не удался, проверьте совместимость архитектуры, квантования и шаблона модели с вашей версией Ollama.

## 6. HTTP API

Запросы выполняются из Ubuntu. При публикации на `127.0.0.1` API не доступен напрямую с хоста VirtualBox. Не открывайте порт в сеть без отдельной настройки защиты: локальный API предназначен для доверенного окружения.

Список моделей и одиночный ответ:

```bash
curl -fsS http://127.0.0.1:11434/api/tags
curl -fsS http://127.0.0.1:11434/api/generate \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5:3b","prompt":"Объясни Docker-том в двух предложениях.","stream":false,"options":{"temperature":0.2,"num_ctx":2048,"num_predict":150}}'
```

Для импортированной модели замените `model` на `my-qwen:gguf`. `stream: false` возвращает один JSON; при `true` ответы идут частями, для просмотра используйте `curl -N`. `temperature` влияет на случайность, `num_ctx` задаёт размер контекста, `num_predict` ограничивает длину генерации. Больший контекст может требовать больше RAM. Дополнительные поля и единицы времени описаны в [API generate](https://docs.ollama.com/api/generate).

Для диалога клиент передаёт историю сообщений в каждом запросе:

```bash
curl -fsS http://127.0.0.1:11434/api/chat \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5:3b","stream":false,"messages":[{"role":"user","content":"Кодовое слово стенда — Маяк."},{"role":"assistant","content":"Запомнил: Маяк."},{"role":"user","content":"Какое кодовое слово стенда?"}]}'
```

Сравните ответ с запросом, где оставлен только последний вопрос. Сервер не получает предыдущие сообщения автоматически: клиент передаёт нужную историю в `messages`. См. [API chat](https://docs.ollama.com/api/chat).

## 7. Docker Compose

Файл [compose.yaml](compose.yaml) использует **внешний** том с точным именем `llm-ollama-data`, поэтому совместим с описанным выше запуском. Создайте том, если его ещё нет. Сначала остановите и удалите старый контейнер, иначе возникнут конфликты имени и порта. Модели в томе сохранятся.

```bash
sudo docker volume create llm-ollama-data
sudo docker stop llm-ollama
sudo docker rm llm-ollama
```

Если старого контейнера нет, пропустите две последние команды. Склонируйте репозиторий в ВМ или перенесите Compose-файл туда; из папки с файлом выполните:

```bash
cd ~/Studying-LLM-01/01-local-llm
sudo docker compose config
sudo docker compose up -d
sudo docker compose ps
sudo docker compose exec ollama ollama list
curl -fsS http://127.0.0.1:11434/api/tags
```

Путь после `cd` — пример: используйте фактическое место расположения файла. `config` проверяет и выводит итоговую конфигурацию; `up -d` создаёт сервис. Compose управляет контейнером, а внешний том остаётся под отдельным управлением. `sudo docker compose down` удаляет контейнер и сеть проекта, сохраняя том. **Внешний том не удаляется даже при `down -v`**; для его удаления нужна отдельная команда из раздела очистки. Подробнее: [тома Compose](https://docs.docker.com/reference/compose-file/volumes/).

## 8. Эксплуатация и диагностика

```bash
sudo docker ps -a
sudo docker logs --tail 100 llm-ollama
sudo docker stats llm-ollama
df -h
free -h
sudo docker system df -v
```

Выйдите из `docker stats` через Ctrl+C. `df` показывает место в файловых системах ВМ, `free` — память. На динамическом виртуальном диске освобождение места внутри Ubuntu не обязательно уменьшает размер файла VDI на хосте.

| Симптом | Что проверить |
|---|---|
| `Connection refused` | `docker ps -a`, логи, запрос именно внутри ВМ; запустите остановленный контейнер. |
| Имя или порт заняты | Проверьте `docker ps -a` и `sudo ss -ltnp`; не запускайте одновременно старый контейнер и Compose. |
| Модель не найдена | `ollama list`, точное имя и тег; убедитесь, что подключён нужный том. |
| Загрузка очень медленная | Проверьте сеть ВМ, повторите загрузку или используйте импорт GGUF. |
| Мало памяти / генерация медленная | `free -h`, `docker stats`; попробуйте меньшую модель и контекст, закройте лишние приложения. Первый запрос включает загрузку модели. |
| Закончилось место | `df -h`, `docker system df -v`; проверьте временные GGUF и ненужные конкретные модели перед удалением. |

Для обновления при запуске через Compose из папки файла выполните `sudo docker compose pull`, затем `sudo docker compose up -d` и повторите проверку API и модели. При запуске через `docker run` новое скачивание образа **не обновляет существующий контейнер**: потребуется пересоздать его командой из раздела 3 с тем же томом. Перед обновлением полезно зафиксировать текущую версию образа; `latest` меняется.

## 9. Безопасная очистка

Сначала проверьте имя контейнера и тома, а также необходимость резервной копии. Не используйте общие команды `docker system prune -a --volumes`: они могут затронуть другие проекты.

**Остановить, сохранив всё:**

```bash
sudo docker stop llm-ollama
sudo docker start llm-ollama
```

**Удалить контейнер, сохранив модели:** при использовании Compose выполните `sudo docker compose down` из папки проекта. При ручном запуске:

```bash
sudo docker stop llm-ollama
sudo docker rm llm-ollama
sudo docker volume ls
```

**Полностью удалить данные стенда:** только после удаления контейнера и проверки, что том не нужен другим контейнерам. Следующая команда безвозвратно удаляет модели и данные Ollama в этом томе:

```bash
sudo docker volume inspect llm-ollama-data
sudo docker volume rm llm-ollama-data
```

При необходимости отдельно удалите образ `sudo docker image rm ollama/ollama:latest`; Docker может отказать, если он используется другим контейнером. Исходный GGUF в домашней папке ВМ и копия на физическом компьютере этими командами не удаляются.

## 10. Самопроверка и шпаргалка

1. Установите две модели и объясните разницу между `ollama list` и `ollama ps`.
2. Удалите контейнер, создайте его заново с тем же томом и проверьте список моделей без повторной загрузки.
3. Отправьте запрос в `/api/generate`, затем передайте историю в `/api/chat`.
4. Перейдите на Compose и убедитесь, что прежние модели видны; выполните `down` и снова `up -d`.

| Задача | Команда |
|---|---|
| Контейнеры | `sudo docker ps -a` |
| Логи | `sudo docker logs --tail 30 llm-ollama` |
| Модели на диске | `sudo docker exec llm-ollama ollama list` |
| Модели в памяти | `sudo docker exec llm-ollama ollama ps` |
| Запустить диалог | `sudo docker exec -it llm-ollama ollama run qwen2.5:3b` |
| Выйти из диалога | `/bye` |
| Проверить API | `curl -fsS http://127.0.0.1:11434/api/tags` |
| Остановить Compose | `sudo docker compose down` |
