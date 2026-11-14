# Разработка

Карта компонентов — [ARCHITECTURE.md](ARCHITECTURE.md), обязательные проверки — [TESTING.md](TESTING.md), независимый вариант — [FORKING.md](FORKING.md). Исторические отчёты сохраняют даты своих проверок; структурный этап 14.11.2026 описан в [REFACTORING_REPORT.md](REFACTORING_REPORT.md).

## Окружение и запуск

macOS 13+, Xcode 15.2+, Swift из выбранного Xcode. Проверенная локальная среда: macOS 13.7.8, Xcode 15.2, Apple silicon. CI использует macos-15. Схема и targets: `HHVacancyCBR`, `HHVacancyCBRTests`, `HHVacancyCBRUITests`; путь проекта `HHVacancyCBR/HHVacancyCBR.xcodeproj`. Внешних Swift packages нет. C bridge Streebog подключён существующим bridging header; компилируется только Bridge.c, включающий сторонний core.

Открыть проект в Xcode, выбрать схему HHVacancyCBR и My Mac, Run. Сеть запускается пользователем кнопкой «Обновить», просмотр сохранённых выборок не требует обновления. Для CLI из корня:

```sh
xcodebuild -project HHVacancyCBR/HHVacancyCBR.xcodeproj -scheme HHVacancyCBR \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Development CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
```

Не подменяйте установленное приложение тестовой сборкой. UI fixtures работают в Debug при `HHVACANCYCBR_UI_TEST_MODE=1`; сценарий задаёт `HHVACANCYCBR_UI_TEST_SCENARIO`. Тесты задают их сами. Production composition не читает фикстуры в Release. Обычные unit и UI-тесты используют синтетические данные; opt-in тесты могут обращаться к сети и некоторые — к установленному приложению, поэтому не включайте их глобально.

## Данные и диагностика

Bundle ID `local.sergey.HHVacancyCBR`. Sandbox хранит файлы внутри контейнера приложения, в `Data/Library/Application Support/HHVacancyCBR`. Не стирайте контейнер для решения ошибки теста. Перед ручной проверкой установленной версии сохраните всю папку, включая `documented-archive-v1`, а не только список вакансий. Старый `favorites.json` не изменяется.

`employers.json` имеет миграцию v1→v2. HH snapshot использует ISO8601 даты; trudvsem snapshot — стандартное Codable Date encoding. Эти форматы различаются намеренно. Не объединяйте их миграцией ради единообразия. При ошибке refresh проверяйте сохранённую дату и сообщения о полноте, а не только количество строк. Для PDF важны исходные ответы, их hashes и observation IDs. Не публикуйте токен или содержимое пользовательского контейнера в issue/логе.

Сохраняйте `-resultBundlePath` и журнал xcodebuild в отдельный каталог: существующий xcresult перезаписывать нельзя. `xcrun xcresulttool get --path <bundle> --format json` позволяет проверить фактически найденные тесты. UI automation требует интерактивного сеанса macOS. Ошибка запуска testmanager — ограничение среды, а не успешная проверка приложения.

## Изменения структуры

Сначала зафиксируйте текущее поведение проверкой на исходнике. Переносите целые типы отдельно от переименования и изменения логики. Сохраняйте private/fileprivate границы, MainActor, Sendable, владение Task, отмену, locks и порядок сохранения/публикации. Различия hh.ru и trudvsem.ru не являются автоматически дублированием.

После добавления или переноса файла обновите Xcode references, group и Sources нужного target. Выполните `python3 scripts/verify_project_sources.py`: каждый Swift/C файл приложения и тестов должен входить ровно один раз в соответствующий target. Исключение — `gost3411-2012-core.c`, включённый в `Bridge.c`: отдельно он не компилируется. `scripts/swift_sources.py` рекурсивно собирает production-файлы для автономных harness, исключая только SwiftUI entry/composition/ContentView. Проверка независимости также рекурсивная.

Следуйте AGENTS.md: работа в main, без новых веток без запроса владельца. Не включайте чужие незавершённые изменения в свой коммит. Сборка DMG требует чистого коммита; не обходите это условие удалением или stash чужой работы. Для проверки подготовленного набора используйте отдельную самостоятельную копию с локальным техническим коммитом и явно фиксируйте, что это SHA артефакта, а не main.

## Артефакты и выпуск

Текущие результаты и доступность доказательств — [VALIDATION.md](VALIDATION.md), карта сохранённых материалов — [validation/README.md](validation/README.md). `build/`, `output/` и `releases/` не являются зависимостями сборки и не хранятся в Git. Перед очисткой сохраняйте уникальные baseline, diff, исходные ответы, xcresult и манифесты; проверяйте контрольные суммы архива. Кэш компилятора воспроизводим, пользовательский контейнер — нет.

Сборка и публикация полноценного GitHub Release описаны в [RELEASING.md](RELEASING.md). Временный артефакт Actions и опубликованный выпуск — разные результаты.
