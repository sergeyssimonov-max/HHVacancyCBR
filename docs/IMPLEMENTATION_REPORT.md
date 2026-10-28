# Отчёт по интеграции hh.ru и trudvsem.ru

В обеих вкладках количество вакансий, количество полевых учреждений и дата обновления размещены в одной строке с PDF-командами, шрифтом 13 pt. Выпадающий выбор сортировки и дублирующая подстрока с уникальными вакансиями удалены.

Реализованы две вкладки существующего приложения, реестр шести организаций, независимые обновления и хранилища, три документированных PDF-режима на каждой вкладке. Bundle ID, минимальная macOS, App Sandbox, авторизация hh.ru и каталог данных сохранены.

## Организации и API

Подтверждённые основные hh.ru ID: Банк России 47858, РОСИНКАС 125886, НСПК 1654251, РНПК 2608647, НСИС 9942121. УК ФКБС остаётся шестой организацией с неподтверждённым hh-профилем. Найденный кандидат 12644406 с сайтом amfbc.ru не включён автоматически. Для повторной ограниченной проверки добавлен `scripts/discover_uk_fkbs.py`; он не изменяет конфигурацию.

ИНН trudvsem.ru соответственно: 7702235133, 7703030058, 7706812159, 7706440687, 7720895647, 7714997584. Полные названия, ОГРН, тип связи, подтверждающие ссылки и проверенные companycode приведены в [реестре](EMPLOYER_REGISTRY.md).

Живыми запросами подтверждены HTTPS, структура конверта API, строковый status, числовой total и страничная семантика offset. При limit=2 страницы 0 и 1 содержали разные пары вакансий, страница 2 была пуста; результат совпал с limit=100. Остальные формы данных и нарушения полноты проверены fixtures. Самостоятельные DTO сохраняют типизированный JSON; нормализованная модель хранит организацию, подразделение, составной ID, регион, классификацию и связи с наблюдениями.

## Независимость и совместимость

hh.ru использует HHAPIClient и прежний VacancyCollectionService. Trudvsem.ru использует отдельные TrudvsemAPIClient и TrudvsemCollectionService. У вкладок отдельные задачи, отмена, результаты, фильтры, поиск, время обновления, сообщения и экспорт. Смена вкладки не запускает сеть. Неполный сбор не становится новым полным снимком.

employers.json мигрирует v1 → v2 атомарным объединением: сохраняет пользовательские имена, комментарии и дополнительные записи, добавляет подтверждённые системные аккаунты и метаданные проверки. Повторная миграция идемпотентна. Старые areas.json, vacancies.json и documented-archive-v1/observations сохраняют пути и читаемость. Новые hh-снимки сохраняют загруженные подробности. Trudvsem использует отдельные employers-trudvsem.json и vacancies-trudvsem.json. Исторический favorites.json не читается, не создаётся и не удаляется.

## PDF

Общая инфраструктура перенесена из FavoriteVacanciesPDFExporter.swift в VacanciesPDFExporter.swift. Сохранены стили, HTML-обработка, страничная верстка, PDF-проверки, выбор каталога и защита от перезаписи. Хранение и синхронизация избранного удалены.

Массовый экспорт фиксирует отфильтрованную выборку и её порядок. hh.ru получает недостающие полные details; trudvsem.ru выводит все содержательные поля ответа. Расчёт частей уточнён: прежняя оценка могла не учитывать страницы реквизитов. Теперь максимум 100 страниц проверяется по фактической части, длинная карточка продолжается с пометкой, текст не теряется. Готовые PDF-части хранятся во временном каталоге. Прогресс включает подготовку, формирование частей и сохранение.

Все режимы требуют исходных ответов соответствующего источника. EmbeddedFiles сохраняют оригинальные байты. Проверяются связь с вакансиями, покрытие каждой вакансии, источник и ГОСТ Р 34.11-2012 (512 бит). Ответы для старых снимков не имитируются. Повреждение или отсутствие материала блокирует экспорт. Старые наблюдения hh.ru читаются.

## Проверки и ограничения

142 unit-теста: 4 штатных opt-in пропуска, 0 ошибок. Проверены UI-сценарии двух вкладок, фильтров, описаний, отмены и PDF-команд. Python: 23/23. Streebog: 11 независимых векторов. Debug и строгий Release собраны. Три режима trudvsem.ru отрендерены Poppler и визуально проверены; хеши извлечённых вложений отдельно сверены через pypdf и gostcrypto. Подробности и итог UI — в [VALIDATION.md](VALIDATION.md).

Удалённый CI не запускался: изменения не отправлялись на GitHub. Workflow, подпись и правила нотарификации сохранены; текст инструкции внутри DMG обновлён для двух источников. Локальные команды проверяют соответствующие сборочные режимы. Commit SHA и результат упаковки DMG сообщаются в итоговом ответе.

Не проверены: выдача trudvsem.ru свыше 10 000 записей и временное разбиение больших живых данных; полная выдача РОСИНКАС (тайм-аут); юридическое подтверждение кандидата УК ФКБС; установка на другом Mac; Developer ID и нотарификация. Непроверенные сценарии не объявляются успешными.

## Created files

- `HHVacancyCBR/HHVacancyCBR/OrganizationRegistry.swift`
- `HHVacancyCBR/HHVacancyCBR/TrudvsemAPIClient.swift`
- `HHVacancyCBR/HHVacancyCBR/TrudvsemModels.swift`
- `HHVacancyCBR/HHVacancyCBR/TrudvsemPDFFormatter.swift`
- `HHVacancyCBR/HHVacancyCBR/TrudvsemViewModel.swift`
- `HHVacancyCBR/HHVacancyCBR/TrudvsemViews.swift`
- `HHVacancyCBR/HHVacancyCBR/VacanciesPDFExporter.swift`
- `docs/IMPLEMENTATION_REPORT.md`
- `scripts/discover_uk_fkbs.py`

## Modified files

- `HHVacancyCBR/HHVacancyCBR.xcodeproj/project.pbxproj`
- `HHVacancyCBR/HHVacancyCBR/ContentView.swift`
- `HHVacancyCBR/HHVacancyCBR/EmployerConfiguration.swift`
- `HHVacancyCBR/HHVacancyCBR/HHModels.swift`
- `HHVacancyCBR/HHVacancyCBR/HHVacancyCBRApp.swift`
- `HHVacancyCBR/HHVacancyCBR/PDFSourceEvidence.swift`
- `HHVacancyCBR/HHVacancyCBR/VacancySearchViewModel.swift`
- `HHVacancyCBR/HHVacancyCBR/VacancySearchViews.swift`
- `HHVacancyCBR/HHVacancyCBR/VacancySnapshotStore.swift`
- `HHVacancyCBR/HHVacancyCBR/employers.json`
- `HHVacancyCBR/HHVacancyCBRTests/HHVacancyCBRTests.swift`
- `HHVacancyCBR/HHVacancyCBRUITests/HHVacancyCBRUITests.swift`
- `README.md`
- `docs/DOCUMENTED_PDF.md`
- `docs/EMPLOYER_REGISTRY.md`
- `docs/FIELD_INSTITUTIONS.md`
- `docs/VALIDATION.md`
- `scripts/benchmarks/README.md`
- `scripts/benchmarks/RuntimeBenchmarks.swift`
- `scripts/benchmarks/build.sh`
- `scripts/verify_independence.py`
- `scripts/release.sh`

## Removed or renamed files

- `HHVacancyCBR/HHVacancyCBR/FavoriteVacanciesPDFExporter.swift`
- `HHVacancyCBR/HHVacancyCBR/FavoriteVacancyStore.swift`
