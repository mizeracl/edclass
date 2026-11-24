#!/usr/bin/env bash
# Поднимает весь локальный стенд EdClass: бэкенд, веб-сервер, эмулятор Android,
# симулятор iOS. Повторный запуск безопасен — уже работающее пропускается.
#
#   ./dev_up.sh            — поднять всё, приложения запустить
#   ./dev_up.sh --rebuild  — пересобрать клиенты (apk/ios/web) перед запуском
#   ./dev_up.sh down       — погасить всё (без стирания данных)
#
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="/var/folders/ty/lwq25rp977lcdf8_5wghfx0m0000gn/T/opencode"
mkdir -p "$LOGDIR"

ANDROID_SDK="${ANDROID_SDK:-$HOME/Library/Android/sdk}"
ADB="$ANDROID_SDK/platform-tools/adb"
EMULATOR="$ANDROID_SDK/emulator/emulator"
AVD_NAME="${AVD_NAME:-edclass}"
IOS_UDID="${IOS_UDID:-54B6DFFF-B48A-488B-B310-9DF8C73C8385}"   # iPhone 17
IOS_NAME="${IOS_NAME:-iPhone 17}"

is_running() { pgrep -f "$1" >/dev/null 2>&1; }

# ---- backend -------------------------------------------------------------
start_backend() {
  if curl -s -m 2 http://localhost:8080/health >/dev/null 2>&1; then
    echo "  бэкенд  :8080 уже работает"
    return
  fi
  echo -n "  бэкенд  :8080 запускаю... "
  (cd "$ROOT/backend" && nohup ./server >"$LOGDIR/backend.log" 2>&1 &)
  sleep 1
  curl -s -m 2 http://localhost:8080/health >/dev/null 2>&1 \
    && echo "ok" || echo "НЕ ОТВЕЧАЕТ (см. $LOGDIR/backend.log)"
}

# ---- web ------------------------------------------------------------------
start_web() {
  if curl -s -o /dev/null -m 2 http://localhost:5050/ 2>/dev/null; then
    echo "  веб     :5050 уже работает"
    return
  fi
  if [ ! -d "$ROOT/build/web" ]; then
    echo "  веб     : build/web не собран, собираю... "
    (cd "$ROOT" && flutter build web --release >"$LOGDIR/web-build.log" 2>&1)
  fi
  echo -n "  веб     :5050 запускаю (build/web)... "
  (cd "$ROOT" && nohup python3 -m http.server 5050 --directory build/web >"$LOGDIR/web.log" 2>&1 &)
  sleep 1
  curl -s -o /dev/null -m 2 http://localhost:5050/ && echo "ok" \
    || echo "НЕ ОТВЕЧАЕТ (см. $LOGDIR/web.log)"
}

# ---- android --------------------------------------------------------------
start_android() {
  if ! "$ADB" get-state >/dev/null 2>&1; then
    echo -n "  Android : загружаю эмулятор ($AVD_NAME)... "
    "$EMULATOR" -avd "$AVD_NAME" -no-snapshot-save -gpu swiftshader_indirect -no-audio \
      >"$LOGDIR/emulator.log" 2>&1 &
    for i in $(seq 1 45); do
      sleep 4
      [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
    done
    echo "ок"
  else
    echo "  Android : эмулятор уже запущен"
  fi
  echo -n "  Android : ставлю APK... "
  "$ADB" install -r "$ROOT/build/app/outputs/flutter-apk/app-debug.apk" >/dev/null 2>&1 \
    && echo "ok" || echo "НЕ УСТАНОВИЛОСЬ (соберите --rebuild)"
  "$ADB" shell am start -n com.edclass.edclass/.MainActivity >/dev/null 2>&1
}

# ---- ios -------------------------------------------------------------------
# В Xcode 27 отдельного приложения Simulator.app больше нет: экран устройства
# показывается в Device Hub (внутри Xcode). Открываем его, а если система ещё
# со старым Xcode — пробуем классическое окно Simulator.
open_ios_gui() {
  local devicehub="/Applications/Xcode.app/Contents/Applications/DeviceHub.app"
  if [ -d "$devicehub" ]; then
    open "$devicehub" 2>/dev/null && return 0
  fi
  open -a Simulator 2>/dev/null
}

start_ios() {
  # Всегда открываем окно GUI: устройство может быть загружено в фоне,
  # а без GUI кажется, что «эмуль не запускается», и flutter run теряет связь.
  open_ios_gui
  sleep 1
  if ! xcrun simctl bootstatus "$IOS_UDID" -b >/dev/null 2>&1; then
    echo -n "  iOS     : загружаю симулятор ($IOS_NAME)... "
    xcrun simctl boot "$IOS_UDID" 2>/dev/null
    xcrun simctl bootstatus "$IOS_UDID" -b >/dev/null 2>&1
    echo "ок"
  else
    echo "  iOS     : симулятор уже запущен"
  fi
  echo "  iOS     : ставлю Runner.app..."
  xcrun simctl install "$IOS_UDID" "$ROOT/build/ios/iphonesimulator/Runner.app" >/dev/null 2>&1 \
    && echo "ок" || echo "НЕ УСТАНОВИЛОСЬ (соберите --rebuild)"
}

# Перезапускает flutter run с нуля: убивает зависшую сессию (иначе лог-захват
# немой и связь теряется), ставит свежий билд и поднимает логирование.
start_ios_run() {
  if pgrep -f "flutter run -d $IOS_UDID" >/dev/null 2>&1; then
    echo -n "  iOS     : перезапускаю flutter run... "
    pkill -f "flutter run -d $IOS_UDID" 2>/dev/null
    sleep 2
  else
    echo -n "  iOS     : запускаю flutter run... "
  fi
  xcrun simctl install "$IOS_UDID" "$ROOT/build/ios/iphonesimulator/Runner.app" >/dev/null 2>&1
  nohup script -q "$LOGDIR/ios.log" \
    flutter run -d "$IOS_UDID" --debug --no-version-check >"$LOGDIR/ios-run.out" 2>&1 &
  echo "pid=$!"
  # Ждём готовности и проверяем, что сессия жива, а не «Lost connection».
  for i in $(seq 1 25); do
    sleep 1
    rg -q "Dart VM Service" "$LOGDIR/ios-run.out" 2>/dev/null && break
  done
  if rg -q "Dart VM Service" "$LOGDIR/ios-run.out" 2>/dev/null; then
    echo "       iOS-логи: $LOGDIR/ios.log"
  else
    echo "  iOS     : НЕ поднялся (см. $LOGDIR/ios-run.out)"
  fi
}

# ---- main -------------------------------------------------------------------
cmd="${1:-up}"

case "$cmd" in
  up)
    echo "Поднимаю стенд EdClass:"
    start_backend
    start_web
    start_android
    start_ios
    start_ios_run
    echo "Готово."
    echo "  веб:      http://localhost:5050/  (на телефонах: http://<ваш-IP>:5050)"
    echo "  логи:     $LOGDIR/{backend,web,emulator,ios}.log"
    ;;
  --rebuild)
    echo "Сборка клиентов (это долго):"
    (cd "$ROOT" && flutter build apk --debug >"$LOGDIR/apk-build.log" 2>&1 && echo "  apk: ok")
    (cd "$ROOT" && flutter build ios --simulator --debug >"$LOGDIR/ios-build.log" 2>&1 && echo "  ios: ok")
    (cd "$ROOT" && flutter build web --release >"$LOGDIR/web-build.log" 2>&1 && echo "  web: ok")
    echo "Запускаю стенд:"
    start_backend
    start_web
    start_android
    start_ios
    start_ios_run
    echo "Готово."
    ;;
  down)
    echo "Гашу стенд (данные эмуляторов сохраняются):"
    "$ADB" shell am force-stop com.edclass.edclass 2>/dev/null
    xcrun simctl terminate "$IOS_UDID" com.edclass.edclass 2>/dev/null
    pkill -f "http.server 5050" 2>/dev/null && echo "  веб: остановлен"
    pkill -f "/server$" 2>/dev/null && echo "  бэкенд: остановлен"
    echo "Эмуляторы не глушу — они грузятся долго. Для жёсткой очистки:"
    echo "  $ADB emu kill  и  xcrun simctl shutdown $IOS_UDID"
    ;;
  *)
    echo "Использование: $0  |  --rebuild  |  down"
    ;;
esac