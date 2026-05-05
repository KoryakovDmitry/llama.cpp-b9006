# Testing the auto-start + watchdog setup

Чек-лист на одну сессию: проверяет, что после `install.sh` оба сервиса
(`mcp-csi-camera`, `llama-server`) поднимаются автоматически, оба
watchdog'а действительно пробят `/healthz` и `/health`, и эскалация
работает на синтетических сбоях. Реальный host1x-stuck на Tegra210 так
не воспроизвести (он нерегулярный) — но если все 5 фаз ниже зелёные,
то когда он случится, система с ним справится сама.

Прогон — около 15 минут, плюс терпение между фазами (watchdog тикает раз
в 30с, начальная задержка `OnBootSec=2min`).

## Pre-flight

Если камера сейчас в host1x-stuck (см. `CSI_CAMERA.md` § "Recovery:
host1x channel stuck"), сначала ребут — иначе фаза 2 завалится не из-за
нашего кода, а из-за наследия:

```bash
sudo reboot
```

Потом открыть SSH-сессию обратно, и:

```bash
cd ~/llama.cpp-b9006
git fetch
git checkout auto-start-services-with-healthcheck
```

## Фаза 1 — собрать новый бинарь

`/healthz` появился именно в этой ветке, без пересборки в ней нет
endpoint'а который потом будет дёргать watchdog.

```bash
cd ~/llama.cpp-b9006/jetson-nano-ability-instruction-based-on-b5050/mcp-csi-camera
cargo build --release
```

Ожидаемо: сборка проходит без warning'ов, бинарь
`target/release/mcp-csi-camera` обновлён по timestamp'у.

## Фаза 2 — smoke-тест `/healthz` без systemd

Прежде чем дёргать `install.sh`, прогнать бинарь руками. Так если что-то
не работает на уровне Rust, мы это увидим без шума от systemd.

### С `--source mock` (без камеры)

```bash
./target/release/mcp-csi-camera --source mock --listen 0.0.0.0:8777 &
SERVER_PID=$!
sleep 2
curl -i http://127.0.0.1:8777/healthz
kill $SERVER_PID
```

Ожидаемо:
```
HTTP/1.1 200 OK
content-type: text/plain; charset=utf-8
content-length: 3

ok
```

### С `--source gstreamer` (реальная камера)

```bash
./target/release/mcp-csi-camera --source gstreamer --listen 0.0.0.0:8777 &
SERVER_PID=$!
sleep 5   # warmup ~1с + запас
curl -i http://127.0.0.1:8777/healthz
kill $SERVER_PID
```

Ожидаемо: те же `200 OK ok`. Если получили `503 stuck` — pipeline стух
(уже до нашего testing-а), нужно отдельно разбираться.

## Фаза 3 — установка systemd

```bash
cd ~/llama.cpp-b9006/jetson-nano-ability-instruction-based-on-b5050/systemd

# сначала dry-run — глазами проверить что подставится
sudo ./install.sh --dry-run | less

# когда устраивает
sudo ./install.sh
```

После установки **обязательно отредактировать**:

- `/etc/default/llama-server` — `LLAMA_HF_MODEL` (наш дефолт может быть
  не тем, что ты хочешь крутить)
- `/etc/default/mcp-csi-camera` — `MCP_CSI_EXTRA_ARGS=--allowed-host
  <твой LAN IP>` под твою сеть

Применить:
```bash
sudo systemctl restart llama-server mcp-csi-camera
```

## Фаза 4 — verify normal operation

Все 4 unit'а должны быть `active`:

```bash
systemctl status mcp-csi-camera llama-server \
                 mcp-csi-camera-watchdog.timer llama-server-watchdog.timer
```

Ручные probe — оба 200:

```bash
curl -i http://127.0.0.1:8777/healthz       # mcp-csi-camera
curl -i http://127.0.0.1:8776/health        # llama-server
```

Таймеры в расписании, ближайшее срабатывание видно:

```bash
systemctl list-timers '*-watchdog.timer'
```

Подождать ~3 минуты (`OnBootSec=2min` + первый `OnUnitActiveSec=30s`), и
заглянуть в журналы watchdog'ов — должны быть пустые (всё ok), либо
содержать строки запусков service-а без recovery-действий:

```bash
journalctl -u mcp-csi-camera-watchdog --since '5 min ago'
journalctl -u llama-server-watchdog --since '5 min ago'
```

Если в журнале есть `escalating` или `restarting` — что-то не так,
прервать и разобраться (см. troubleshooting в `README.md`).

## Фаза 5 — recovery tests (синтетические сбои)

Цель — убедиться, что watchdog действительно реагирует на типичные
паттерны сбоев. Используем `kill -STOP` (заморозка процесса — он жив, но
не отвечает) и `kill -KILL` (имитация crash) на реальные PID-ы юнитов.

### Тест A — «deliberate stop» уважается

Watchdog НЕ должен поднимать остановленный руками сервис.

```bash
sudo systemctl stop mcp-csi-camera
sleep 70   # 2 watchdog-цикла
journalctl -u mcp-csi-camera-watchdog --since '2 min ago' | tail -20
sudo systemctl start mcp-csi-camera
```

Ожидаемо: в логе строка типа
```
[watchdog] mcp-csi-camera.service is inactive (deliberately stopped) — skipping probe
```
и **никаких** `escalating` или `stage 1`.

### Тест B — Restart=on-failure ловит crash

```bash
PID=$(systemctl show -p MainPID --value mcp-csi-camera)
sudo kill -KILL $PID
sleep 10
systemctl status mcp-csi-camera   # снова active, новый PID
journalctl -u mcp-csi-camera --since '20 sec ago'
```

Ожидаемо: unit перезапустился через ~5с (наш `RestartSec=5s`),
status active с другим MainPID.

### Тест C — `process alive but hung` ловится watchdog'ом

Это самое важное — ради этого вся обвязка. `kill -STOP` замораживает
процесс: он есть в `ps`, MainPID жив, но любые TCP-запросы зависают.

```bash
PID=$(systemctl show -p MainPID --value mcp-csi-camera)
sudo kill -STOP $PID
echo "frozen at $(date), wait 90s"
sleep 90
journalctl -u mcp-csi-camera-watchdog --since '2 min ago' | tail -20
```

Ожидаемо: в логе watchdog'а должны быть две записи:
```
[watchdog] /healthz failed (http=000 state=0 unit=active) — escalating
[watchdog] stage 1: systemctl restart mcp-csi-camera.service
```
И сервис снова работает (`kill -STOP` отменился через restart):

```bash
systemctl status mcp-csi-camera         # active, новый PID
curl -i http://127.0.0.1:8777/healthz   # 200 ok
```

### Тест D — то же для llama-server

```bash
PID=$(systemctl show -p MainPID --value llama-server)
sudo kill -STOP $PID
sleep 90
journalctl -u llama-server-watchdog --since '2 min ago' | tail -20
```

Ожидаемо:
```
[llama-watchdog] /health unreachable (curl failed, unit=active) — restarting llama-server.service
```

### Тест E — модель грузится, watchdog НЕ должен дёргать

**Ключевой тест** на корректность 503-ветки. На Nano загрузка GGUF
занимает 10-30с — без 503-ветки в watchdog скрипте мы бы рестартили
сервер прямо в момент загрузки и зацикливались.

```bash
sudo systemctl restart llama-server
echo "restarted at $(date), wait for watchdog tick"
sleep 60
journalctl -u llama-server-watchdog --since '1 min ago' | tail -10
journalctl -u llama-server --since '2 min ago' | tail -20
```

Ожидаемо в журнале watchdog: одна из двух строк:
- `[llama-watchdog] /health 503 (loading model) — skipping`
- `[llama-watchdog] llama-server.service is activating — skipping probe`

**Чего НЕ должно быть**: `restarting llama-server.service` во время
загрузки модели. Если такое есть — мы зациклились бы и тест проваливаем,
надо смотреть что вернул реальный `/health` в момент проверки.

После того как модель загрузилась, журнал llama-server должен показать
строку готовности (`HTTP server is listening` или подобное), а
следующий tick watchdog'а — здоров (`exit 0`, без записей).

## Что дальше — мониторинг в проде

Watchdog тихий когда всё ok — `journalctl -u *-watchdog -e` будет
пустоват. Это нормально. Когда что-то пойдёт не так — там появятся
recovery-сообщения с timestamp'ами.

Полезные кнопки на каждый день:

```bash
# одной командой — что сейчас с системой
systemctl status mcp-csi-camera llama-server \
                 mcp-csi-camera-watchdog.timer llama-server-watchdog.timer

# когда ближайший probe
systemctl list-timers '*-watchdog.timer'

# посмотреть были ли recovery за последний час
journalctl -u 'mcp-csi-camera-watchdog' -u 'llama-server-watchdog' \
           --since '1 hour ago' | grep -iE 'escal|restart|reboot'

# текущий state эскалации камеры (0 = всё ок)
cat /run/mcp-csi-camera-watchdog/state 2>/dev/null || echo "no state file = clean"

# когда был последний авто-ребут (если был вообще)
cat /var/lib/mcp-csi-camera-watchdog/last-reboot 2>/dev/null \
  | xargs -I{} date -d @{}
```

## Если что-то идёт не так

См. `README.md` § Troubleshooting — там разобраны частые случаи (state
застрял в 3, /healthz возвращает 503 при работающем view_scene,
слишком частые ребуты). Если и там нет — `journalctl -xe` сразу после
сбоя обычно даёт достаточно контекста.
