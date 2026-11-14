# Проверки

Все команды ниже выполняются из корня, в macOS с Xcode и выбранным toolchain. Обычный набор не обращается к живым API. Результаты этапа рефакторинга 14.11.2026 и ограничения — в [REFACTORING_REPORT.md](REFACTORING_REPORT.md); прежние отчёты не заменяют запуск.

## Обязательный набор

```sh
python3 scripts/verify_independence.py
python3 scripts/verify_project_sources.py
python3 -m unittest discover -s scripts/tests -v
xcodebuild -project HHVacancyCBR/HHVacancyCBR.xcodeproj -scheme HHVacancyCBR \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Checks CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  -resultBundlePath build/Checks.xcresult test
xcodebuild -project HHVacancyCBR/HHVacancyCBR.xcodeproj -scheme HHVacancyCBR \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/StrictRelease -disableAutomaticPackageResolution \
  SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Используйте новый путь xcresult для каждого прогона. Полный Debug `test` включает сборку, unit и UI; для отдельного запуска добавьте `-only-testing:HHVacancyCBRTests` или `-only-testing:HHVacancyCBRUITests`. Для UI требуется интерактивный сеанс macOS с разрешением автоматизации. CI `.github/workflows/ci.yml` дополнительно разделяет Debug build/unit, strict Release и UI на jobs; он не устанавливает сборку в `/Applications`.

В проверенном выпуске `v1.3.5-16` (`92934ec`) найдено 188 unit-тестов и 22 UI-теста; при обычном запуске штатно пропускаются 5 unit и 2 UI opt-in сценария. Unit-тесты находятся в тематических extensions `HHVacancyCBRTests` и классе `PDFSourceEvidenceTests`, UI — в двух исходных UI-классах. У предыдущего `v1.3.4-15` (`b70cd73`) было 183 unit и 21 UI: пять unit и один UI добавлены исправлениями `e5a61db` / `bac67db`. В форке считайте фактически найденные тесты, а не подгоняйте набор под эти исторические числа. Проверка inventory:

```sh
python3 scripts/compare_test_inventory.py /path/to/before/source /path/to/after/source
```

Точные параметры инструмента доступны через `--help`. Source inventory дополняет фактический discovery из xcresult, не заменяет исполнение. Shared test support имеет internal visibility только внутри test target; production public API не расширен.

## Что фиксируют проверки

Unit fixtures покрывают обе модели, фильтры/порядок, пустые и большие выдачи, DTO/повреждения, повторные страницы и дубли, API retries/429/5xx, deadlines, cancellation/races, общую очередь обновлений, старые/повреждённые/future snapshots и конфигурацию с пользовательскими записями. Исходные snapshots не заменяются при неполноте; чтение без сети и независимость источников проверяются отдельно. Поведение ошибки записи HH и trudvsem различается — не унифицируйте его под видом переноса.

PDF-проверки охватывают личный/статистический/массовый экспорт, 6500 абзацев, ограничение 100 страниц на часть, текст и ссылки, исходные bytes, Streebog, коллизии, отмену/rollback и отсутствие исходных материалов. UI проверяет обе вкладки, поиск/фильтры/геометрию, ошибки, отмену и сохранение состояния. Не заменяйте сценарии одной проверкой успешной компиляции.

## Сравнение PDF и производительности

Используйте [инструкции harness](../scripts/benchmarks/README.md). `reliability` работает только с синтетическими ответами и виртуальным временем. `scripts/verify_streebog.py` независимо сверяет C bridge с `gostcrypto==1.2.5`; это опциональная Python-зависимость для проверки, не зависимость приложения. Обычный unit также содержит опубликованные контрольные векторы. Не обновляйте стороннюю реализацию ради оформления.

PDF equivalence harness компилируется с одним и тем же fixture-кодом против before/after production. Время заморожено только в его процессе, даты и локаль фиксированы, исходные receipts синтетические и изолированные. Сравниваются весь извлечённый текст без нормализации, порядок и число страниц/частей, растры всех страниц, имена и исходные JSON bytes/hash. Весь PDF может различаться служебными ID/метаданными CoreGraphics: это не повод игнорировать различия в значимых датах или содержимом. Просмотрите обычные страницы и границы длинной карточки после render; сохраните файлы до и после.

Для сборщика, массового PDF, статистики, памяти и main-actor heartbeat выполните минимум пять запусков каждого набора до и после. Один compiler/архитектура/locale/timezone/permissions, без параллельных сборок и UI-тестов. RSS и heartbeat включают накладные расходы harness; это не метрика задержки кадров SwiftUI. Исходный `search 1000` имеет ограничение supplemental fixture; используйте описанный допустимый `search 200`, а большие коллекции дополнительно проверяйте unit-тестами. Не скрывайте этот исходный отказ и не выдавайте его за production-регрессию.

`FilterBenchmarks.swift` отдельно проверяет обе ViewModel на пустой выборке и 10 000 вакансий: 12 сочетаний поиска/фильтров, точный порядок ID и отсутствие сети. Один и тот же fixture-код компилируется против before/after, даты фиксированы, используются только временные snapshots. Сравнивайте digest и количество результатов каждого сценария; для времени и RSS берите медианы минимум пяти процессов. Команды сборки и запуска находятся в инструкции harness выше.

`scripts/extract_named_ui_screenshots.py` извлекает именованные снимки из xcresult и сравнивает исходные RGBA-пиксели без масок. Сохраняйте несовпадения и анализируйте их: рамка окна, focus ring, мигающий caret и рабочий стол могут зависеть от состояния macOS. Даты проверяйте отдельными парными прогонами с фиксированным временем только в тестовом приложении; не удаляйте даты из эталона. Геометрию и поведение одновременно должны подтверждать неизменённые UI assertions.

## Живая сеть — только opt-in

По умолчанию пропускаются live HH, live cancellation, Trud live и PDF performance XCTest, а также две проверки установленной версии через UI. Ищите точные flags через `rg 'HHVACANCYCBR_RUN_|HH_RUN_PERFORMANCE_TESTS' HHVacancyCBR/HHVacancyCBRTests HHVacancyCBR/HHVacancyCBRUITests`. Переменная должна попасть в окружение **test runner**, например EnvironmentVariables соответствующего `.xctestrun`; простого export для xcodebuild может быть недостаточно. `HH_RUN_PERFORMANCE_TESTS=1` включает `testOptInPDFRenderingMetrics` (пять SDK-измерений clock/CPU/memory), не включает сеть и применяется отдельно к before/after без параллельных нагрузок.

Не используйте живую выдачу как эталон рефакторинга. Opt-in UI-тесты `testOptInInstalledTrudLiveRefreshButton` и `testOptInInstalledHHLiveRefreshAndBothSourcesPersist` специально читают/обновляют нормальные данные `/Applications/ЦБВакансии.app`; их запускают только по отдельному запросу, с backup всей папки данных. Во время структурного сравнения они были выключены; отдельные реальные прогоны установленной сборки приведены в [INSTALLATION_CHECK_2026-11-14.md](INSTALLATION_CHECK_2026-11-14.md).

## Чистая сборка и локальный DMG

Этот этап нужен при подготовке нового бинарного выпуска. Для изменений только документации достаточно проверки ссылок/команд, Python-проверок и обычного CI точного SHA; установленное приложение и опубликованный DMG не заменяются. CI выполняет собственные сборки в чистом checkout, не устанавливая их на Mac владельца.

Проверьте финальный набор в самостоятельном чистом checkout/экспорте без build, пользовательских файлов, абсолютных paths, соседнего repo и неотслеживаемых зависимостей. В чистом коммите:

```sh
bash scripts/release.sh --output-dir "$PWD/releases/verification"
```

Выберите новый output directory. Сценарий сам выполняет `git archive`, strict Release, подпись/entitlements, hardened runtime, hdiutil verification и безопасную публикацию локальных двух файлов. Это не публикация GitHub release. Проверка повторного запуска в уже занятый output должна завершиться отказом, не изменив готовый DMG/hash. Developer ID/нотаризация остаются опциональными и требуют настроек владельца. При dirty main не коммитьте чужую работу: используйте явную standalone snapshot-копию, записав её технический SHA в отчёт.

## Где искать результаты

[VALIDATION.md](VALIDATION.md) отделяет локальные проверки, удалённый CI, реальные обновления и исторические отчёты. Сводки доступны в [validation/](validation/README.md), большие исходные материалы — в проверенном локальном архиве владельца. Их архивирование не заменяет свежий обязательный прогон для нового релизного SHA. Для документационной уборки повторные дорогие измерения PDF и производительности не нужны, если код и проверяемые контракты не менялись.
