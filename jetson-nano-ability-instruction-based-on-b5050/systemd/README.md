# systemd auto-start + healthcheck for llama-server and mcp-csi-camera

Поднимает оба сервиса (`llama-server` и `mcp-csi-camera`) как штатные
systemd-юниты с авто-стартом при загрузке и авто-рестартом при падении.
Для CSI-камеры дополнительно прикручен watchdog-таймер: каждые 30 секунд
дёргает `/healthz` и при провале эскалирует по лесенке вплоть до
автоматического `reboot` (с rate-limit 1 раз в час).

## Что устанавливается

```
/etc/systemd/system/
  llama-server.service               # rllama-server + Restart=on-failure
  llama-server-watchdog.service      # one-shot, вызывается из таймера
  llama-server-watchdog.timer        # каждые 30s после OnBootSec=2min
  mcp-csi-camera.service             # mcp-csi-camera + Restart=on-failure
  mcp-csi-camera-watchdog.service    # one-shot, вызывается из таймера
  mcp-csi-camera-watchdog.timer      # каждые 30s после OnBootSec=2min

/etc/default/
  llama-server                       # LLAMA_HF_MODEL, LLAMA_ARGS
  mcp-csi-camera                     # MCP_CSI_LISTEN, MCP_CSI_EXTRA_ARGS, ...

/etc/sudoers.d/
  mcp-watchdog                       # ОПЦИОНАЛЬНО (--with-sudoers)
```

State watchdog-а живёт в:
- `/run/mcp-csi-camera-watchdog/state` — текущая стадия эскалации (0/1/2/3),
  очищается ребутом
- `/var/lib/mcp-csi-camera-watchdog/last-reboot` — timestamp последнего
  авто-ребута, переживает ребут (нужно для rate-limit)

## Установка

С Jetson:

```bash
cd ~/llama.cpp-b9006/jetson-nano-ability-instruction-based-on-b5050/systemd
sudo ./install.sh
```

Скрипт сам подхватит:
- `--user` — из `$SUDO_USER` (т.е. `diikorr` если ставишь через `sudo`)
- `--repo-root` — из своего расположения (родитель папки `systemd/`)
- `--llama-bin` — `which rllama-server` от имени user-а, иначе fallback
  на `~/<user>/.local/bin/rllama-server`

Можно явно:

```bash
sudo ./install.sh \
  --user diikorr \
  --repo-root /home/diikorr/llama.cpp-b9006 \
  --llama-bin /home/diikorr/.local/bin/rllama-server
```

Превью без записи:
```bash
sudo ./install.sh --dry-run
```

## После установки — обязательная конфигурация

Пройдись по `/etc/default/llama-server` и проверь `LLAMA_HF_MODEL` —
скрипт ставит дефолт `unsloth/Qwen3.5-0.8B-GGUF:Q8_0`, может быть не то,
что ты хочешь. Аналогично `/etc/default/mcp-csi-camera` — там
`--allowed-host 192.168.178.59`, под твою сеть может быть другой IP.

После правки:
```bash
sudo systemctl restart llama-server
sudo systemctl restart mcp-csi-camera
```

## Проверка работы

```bash
# юниты живые
systemctl status mcp-csi-camera llama-server \
                 mcp-csi-camera-watchdog.timer llama-server-watchdog.timer

# /healthz отвечает (camera, активный probe)
curl -i http://127.0.0.1:8777/healthz       # 200 ok / 503 stuck

# /health отвечает (llama-server, встроенный)
curl http://127.0.0.1:8776/health            # {"status":"ok"} при загрузке - 503

# когда watchdog в следующий раз стрельнёт
systemctl list-timers '*-watchdog.timer'

# логи
journalctl -u mcp-csi-camera -f                  # live camera
journalctl -u mcp-csi-camera-watchdog -e         # последние пробы camera
journalctl -u llama-server -f                    # live llama
journalctl -u llama-server-watchdog -e           # последние пробы llama
```

## Что делают watchdog-и (recap)

### Камера (`mcp-csi-camera-watchdog`)

Каждые 30 секунд:
1. `curl http://127.0.0.1:8777/healthz` с таймаутом 5с
2. Если 200 → reset state, выход.
3. Если не 200 → эскалация по `state`:

| state | действие |
|-------|----------|
| 0     | `systemctl restart mcp-csi-camera` (~2с downtime) |
| 1     | `systemctl restart nvargus-daemon && systemctl restart mcp-csi-camera` (~5с) |
| 2     | `systemctl reboot`, но не чаще раза в час (rate-limit) |
| 3     | sudden death — больше ничего не делаем, ждём ручного вмешательства |

Любой успешный пробинг сбрасывает state в 0. State в `/run/...` —
ребут даёт fresh start.

`/healthz` сделан **активным** пробом: проверяет, что pipeline в Playing
**и** реально отдаёт кадр (`try_pull_sample` с таймаутом 500ms). Это
ловит ровно ту проблему которая на Tegra210 не лечится `Restart=on-failure`:
процесс жив, MCP отвечает на handshake, но из-за `nvbuf_utils: dmabuf_fd -1`
(host1x stuck) ни один `view_scene` не возвращает кадр.

### llama-server (`llama-server-watchdog`)

Каждые 30 секунд:
1. `curl http://127.0.0.1:8776/health` с таймаутом 5с
2. Ветвление по HTTP-коду + телу:

| код   | тело                          | действие |
|-------|-------------------------------|----------|
| 200   | `{"status":"ok"}`             | healthy, выход |
| 200   | что-то другое                 | reverse-proxy mismatch, restart |
| 503   | `{"error":"Loading model"}`   | модель грузится, **не трогаем** |
| 000   | (curl упал — таймаут / refused) | dead, restart |
| 4xx/5xx прочие | —                    | restart |

503-ветка важна: на Nano загрузка GGUF в RAM+VRAM занимает 10-30с, и без
этой ветки watchdog рестартил бы сервер прямо во время загрузки —
бесконечный цикл. Без state-машины и rate-limit — llama stateless,
рестарт чинит всё что чинится; если модель сломана / CUDA лежит — unit
паркуется в failed после `StartLimitBurst=5/300s`.

## Типичные операции

```bash
# временно остановить (watchdog уважает остановку — не будет пытаться поднять)
sudo systemctl stop mcp-csi-camera

# выключить совсем (не стартует на следующем буте)
sudo systemctl disable mcp-csi-camera

# временно отключить watchdog (например, во время отладки камеры)
sudo systemctl stop mcp-csi-camera-watchdog.timer

# поменять конфиг и применить
sudo nano /etc/default/mcp-csi-camera
sudo systemctl restart mcp-csi-camera

# поменять unit (например, новый флаг в ExecStart) — отредактируй .in,
# и снова прогони install.sh
sudo ./install.sh
```

## Удаление

```bash
sudo ./install.sh --uninstall
```

Снимает enable, останавливает, удаляет unit-файлы и optional sudoers.
**Не трогает** `/etc/default/*` и persistent state (`/var/lib/...`) —
это твоя конфигурация и она может быть нужна, если решишь переустановить.
Удалять руками если точно не нужно.

## Опциональный sudoers

По умолчанию watchdog запускается под root через systemd, и sudoers ему
не нужен. Файл `sudoers.d-mcp-watchdog.in` нужен только если хочется
запускать `mcp-csi-camera-watchdog.sh` руками из-под обычного юзера
(например, для теста). Деплоить так:

```bash
sudo ./install.sh --with-sudoers
```

`install.sh` валидирует синтаксис через `visudo -cf` перед тем как
оставить файл — битый sudoers ломает `sudo` system-wide, поэтому проверка
обязательна.

## Troubleshooting

**`systemctl start mcp-csi-camera` сразу падает с `Failed to create CaptureSession`:**
```bash
sudo systemctl restart nvargus-daemon
sudo systemctl restart mcp-csi-camera
```
Это level-1 в нашей лесенке, watchdog бы это сделал сам через 30с — но
руками быстрее.

**`/healthz` возвращает 503 а `view_scene` через MCP при этом работает:**
Возможно гонка с одновременным `view_scene` — пробник украл кадр у
запроса (max-buffers=1 в appsink). Если это устойчиво воспроизводится,
снизить частоту watchdog в timer-е (`OnUnitActiveSec=60s`) или увеличить
`--health-probe-timeout-ms` в `MCP_CSI_EXTRA_ARGS`.

**Watchdog ушёл в state=3 и отказывается что-либо делать:**
```bash
# посмотреть последние эскалации
journalctl -u mcp-csi-camera-watchdog -e
# посмотреть kernel-side что в камере
dmesg | grep -iE 'imx219|isp|nvbuf|argus' | tail -20
# исправить руками (или ребутнуть), потом сбросить state
sudo rm /run/mcp-csi-camera-watchdog/state
```
state=3 это намеренная "дальше не лезу" точка — обычно означает либо
hardware (шлейф, сенсор), либо конфигурацию (неправильный sensor-mode в
DTB). Посмотри `dmesg | grep imx219` — если там `probe -121` или
`-EREMOTEIO`, это точно шлейф.

**Слишком частые ребуты от watchdog-а:**
Подкрутить cooldown:
```bash
echo 'WATCHDOG_REBOOT_COOLDOWN_SEC=10800' | sudo tee /etc/default/mcp-csi-camera-watchdog
sudo systemctl restart mcp-csi-camera-watchdog.timer
```
(10800 = 3 часа). Файл подхватывается через `EnvironmentFile=-` в
watchdog-сервисе.
