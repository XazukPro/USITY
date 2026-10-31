# Окружение разработки

Проверено на Mac с Apple Silicon 31.10.2026. Этот документ фиксирует состояние рабочего Mac капитана команды. У каждого участника пути к SDK будут своими.

## Уже готово

- GitHub: приватный `XazukPro/USITY`, локальная ветка `main` связана с `origin/main`.
- Flutter 3.47.9 и Dart 3.13.7: `/Users/antonpetriev/Documents/Codex/toolchains/flutter`.
- VS Code: расширения Flutter 3.146.0, Dart 3.146.0 и Python 2026.10.0.
- Docker Desktop установлен и запущен; `docker info` подтвердил доступ к серверу 29.5.3.
- PyCharm и PostgreSQL.app уже установлены. Базу данных проекта будем запускать через Docker Compose после создания backend.

## Что еще нужно для мобильных эмуляторов

`flutter doctor -v` сейчас показывает отсутствие Android SDK, полной Xcode и CocoaPods. При этом Flutter запускается, доступны macOS и Chrome как цели разработки.

1. Установить полную Xcode из App Store и компоненты iOS Simulator. После установки выполнить команды, которые предложит `flutter doctor` (`xcode-select`, `xcodebuild -runFirstLaunch`), и настроить CocoaPods для нативных Flutter-плагинов.
2. Установить Android Studio с Android SDK, Android SDK Command-line Tools, Android Emulator и системным образом ARM64; создать Android Virtual Device.
3. Добавить `/Users/antonpetriev/Documents/Codex/toolchains/flutter/bin` в пользовательский `PATH`, чтобы команды `flutter` и `dart` работали без полного пути. В VS Code при необходимости указать этот каталог как Flutter SDK.
4. Перезапустить терминал и VS Code, затем выполнить `flutter doctor -v` и устранить оставшиеся замечания.

До настройки `PATH` используйте полный путь:

```bash
/Users/antonpetriev/Documents/Codex/toolchains/flutter/bin/flutter doctor -v
```

## Проверки после появления исходного кода

- Mobile: `flutter analyze`, `flutter test`, затем интеграционные сценарии на iOS Simulator и Android Emulator.
- Backend и бот: линтер, типизация и тесты, закрепленные в конфигурации соответствующего Python-пакета.
- GitHub Actions: запускать те же проверки на pull request. Настроить после добавления первого исходного модуля, чтобы workflow действительно проверял код.

Секреты и реальные сообщения Telegram не помещать в репозиторий. Для локального запуска использовать `.env` и публиковать только `.env.example` с именами переменных.
