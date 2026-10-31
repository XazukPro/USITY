# Окружение разработки

Проверено на Mac с Apple Silicon 31.10.2026. Этот документ фиксирует состояние рабочего Mac капитана команды. У каждого участника пути к SDK будут своими.

## Уже готово

- GitHub: приватный `XazukPro/USITY`, локальная ветка `main` связана с `origin/main`.
- Flutter 3.47.9 и Dart 3.13.7: `/Users/antonpetriev/Documents/Codex/toolchains/flutter`.
- VS Code: расширения Flutter 3.146.0, Dart 3.146.0 и Python 2026.10.0.
- Локальная `.vscode/settings.json` указывает путь Flutter SDK для VS Code; файл исключен из Git, потому что путь у каждого участника свой.
- Flutter добавлен в `PATH` через пользовательский `.zprofile`; проверено в новой login shell.
- Xcode 27.2 установлен, лицензия принята, `xcode-select` указывает на полный Xcode. iOS 27.2 Simulator установлен; `flutter devices` обнаружил iPhone Duo.
- Android Studio Rabbit 2 (2026.2.2), Android SDK, Command-line Tools и ARM64-образы Android 36/37 установлены. Лицензии приняты. AVD `USITY_API36` загрузился до `sys.boot_completed=1` и обнаружен `flutter devices`.
- Homebrew 7.0.11 и CocoaPods 1.17.0 установлены; `pod` доступен в новой login shell.
- Docker Desktop установлен и запущен; `docker info` подтвердил доступ к серверу 29.5.3.
- PyCharm и PostgreSQL.app уже установлены. Базу данных проекта будем запускать через Docker Compose после создания backend.

## Проверка окружения

`flutter doctor -v` завершился с `No issues found!`: Flutter, Android toolchain, Xcode, CocoaPods и сетевые ресурсы готовы. `flutter devices` обнаруживал Android 36 AVD и iPhone Duo во время их запуска.

Когда начнется разработка, запустить AVD через `flutter emulators --launch USITY_API36`, а список устройств проверить `flutter devices`. Для iOS запускать симулятор через Device Hub в Xcode или `xcrun simctl`. Первую сборку на обоих эмуляторах проверить после появления исходного кода приложения.

Эмуляторы после проверки остановлены для экономии памяти. Docker Engine оставлен включенным: в нем работает контейнер другого проекта. Окна Xcode, Android Studio, App Store и VS Code закрыты; Safari оставлен открытым.

## Проверки после появления исходного кода

- Mobile: `flutter analyze`, `flutter test`, затем интеграционные сценарии на iOS Simulator и Android Emulator.
- Backend и бот: линтер, типизация и тесты, закрепленные в конфигурации соответствующего Python-пакета.
- GitHub Actions: запускать те же проверки на pull request. Настроить после добавления первого исходного модуля, чтобы workflow действительно проверял код.

Секреты и реальные сообщения Telegram не помещать в репозиторий. Для локального запуска использовать `.env` и публиковать только `.env.example` с именами переменных.
