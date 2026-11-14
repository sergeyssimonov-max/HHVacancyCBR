# Независимый форк

Инструкция ведёт от получения исходников до независимой установки и выпуска. Для сборки нужны Mac с Apple silicon, macOS 13+, Xcode 15.2+, Git и Python 3; внешние Swift packages не нужны. Рабочая папка и архивы прежних проверок автора не требуются.

У основного проекта пока нет отдельной лицензии: условия публичного распространения кода должен определить владелец. Разрешение использовать встроенный токен не заменяет лицензию на код. Сохраняйте [лицензию Streebog](../HHVacancyCBR/HHVacancyCBR/Vendor/Streebog/LICENSE) и [уведомление о его происхождении](../HHVacancyCBR/HHVacancyCBR/Vendor/Streebog/PROVENANCE.md).

Порядок работы: **получить исходники → выполнить исходные проверки → выбрать отдельную идентичность → изменить организации/оформление → повторить тесты → выпустить собственный пакет**. Сначала настройте отдельный Bundle ID, затем запускайте форк с реальными данными рядом с оригиналом.

Все короткие имена Swift-файлов и `Assets.xcassets` ниже отсчитываются от `HHVacancyCBR/HHVacancyCBR/`. Команды выполняются из корня.

## Получение и обновление исходников

Создайте fork средствами GitHub, затем используйте адрес своего репозитория вместо примера:

```sh
git clone https://github.com/YOUR_ACCOUNT/HHVacancyCBR.git
cd HHVacancyCBR
git remote add upstream https://github.com/sergeyssimonov-max/HHVacancyCBR.git
git fetch upstream
```

Доступ к исходному репозиторию должен быть у используемого GitHub-аккаунта. `origin` должен указывать на ваш форк, `upstream` — на HHVacancyCBR. Проверьте это через `git remote -v`; не отправляйте изменения в upstream по инструкции для собственного релиза.

До изменений выполните команды ниже, затем полный набор из [TESTING.md](TESTING.md). Команды не требуют личного токена или прежних пользовательских данных:

```sh
git status --short --branch
xcodebuild -version
python3 --version
python3 scripts/verify_independence.py
python3 scripts/verify_project_sources.py
python3 -m unittest discover -s scripts/tests -v
```

`verify_independence.py` проверяет конкретные имя, Bundle ID, storage directory и реестр организаций оригинала. После согласованного изменения этих параметров обновите ожидаемые значения и их тесты; не удаляйте проверку ради успешного запуска. `verify_project_sources.py` сверяет membership Swift/C-файлов с Xcode targets.

Перед получением следующих изменений сохраните собственную работу отдельным коммитом. `git fetch upstream` не меняет файлы; сравните `git log --oneline HEAD..upstream/main` и `git diff HEAD...upstream/main`, затем применяйте выбранные изменения или `git merge upstream/main`, разрешая конфликты по смыслу. Не копируйте целиком настройки оригинала поверх новой идентичности. Повторите проверки после merge. В исходном репозитории работа идёт в main; AGENTS.md своего форка должен явно описывать ваш порядок работы.

## Идентичность и параллельная установка

Обычный запуск копии с `local.sergey.HHVacancyCBR` использует контейнер оригинала, даже если `.app` лежит в другом каталоге. Изолированные тестовые fixtures не защищают обычный Run с реальными данными. Минимальная карта изменений:

| Что выбрать | Где согласовать | Что проверить |
|---|---|---|
| Собственный Bundle ID | Debug/Release основного target и IDs тестовых targets в `project.pbxproj` | Разные sandbox-контейнеры оригинала и форка |
| Название приложения | `PRODUCT_NAME`, product references, `TEST_HOST`, заголовок окна, иконка | Запуск нужного bundle и тестового host |
| Каталог хранения | `ApplicationSupportLocation.directoryName` и текст его ошибки | Данные форка не появляются в каталоге оригинала |
| Тестовая идентичность | Fixtures, временные каталоги, opt-in installed UI targets | Тесты форка не управляют `/Applications/ЦБВакансии.app` |
| Выпуск и проверки | `scripts/release.sh`, `verify_independence.py`, Python-тесты, workflows, README | Имя DMG, embedded SHA и ссылки принадлежат форку |

Выберите собственные bundle ID, название и storage directory. В `HHVacancyCBR/HHVacancyCBR.xcodeproj/project.pbxproj` согласованно измените PRODUCT_BUNDLE_IDENTIFIER основного приложения и тестовых targets, PRODUCT_NAME, product references, paths, TEST_HOST/TEST_TARGET_NAME, Info.plist-настройки, entitlements paths и схему в `HHVacancyCBR/HHVacancyCBR.xcodeproj/xcshareddata/xcschemes/HHVacancyCBR.xcscheme`. При переименовании targets обновите все CLI/CI selectors.

В `HHVacancyCBRApp.swift` задайте заголовок окна, в Assets.xcassets/AppIcon.appiconset — собственную иконку. `HHVacancyCBR/Scripts/render_icon.py` генерирует иконку текущего продукта, его входные обозначения тоже требуют проверки. В `ApplicationSupportLocation.swift` замените `directoryName`; собственный bundle ID создаст отдельный sandbox-контейнер. Не направляйте новый продукт в старый контейнер и не добавляйте автоматическое копирование данных оригинала.

Согласуйте префиксы `HHVACANCYCBR_` в AppComposition и тестах, temporary directory prefixes в fixtures и `PDFSourceEvidence`, имена ресурсов и артефактов. Найдите оставшиеся упоминания через `rg -n 'HHVacancyCBR|HHVACANCYCBR|ЦБВакансии|local.sergey' HHVacancyCBR scripts .github README.md docs`. Не делайте слепую замену внутри пользовательских данных, JSON keys, исходных API identifiers или стороннего кода.

В `scripts/release.sh`, `scripts/publish_release.py`, Python-тестах, CI/release workflows и `scripts/verify_release_entitlements.py` проверьте product path, имена DMG, bundle IDs и подпись. `verify_independence.py` должен защищать новую идентичность, а не просто перестать проверять старую. Обновите opt-in UI проверки установленного приложения: их `/Applications` target обязан указывать на форк. В документации и README замените ссылки на origin/releases.

После сборки установите оригинал и форк рядом, проверьте разные bundle IDs и контейнеры, чтение и сохранность обоих наборов данных после перезапуска. Сетевые проверки проводите отдельно по своему решению. При проверке только сохранения не нажимайте «Обновить»: запишите счётчики, даты и хеши снимков до и после завершения процесса. Ни название окна, ни другое имя `.app` сами по себе не обеспечивают изоляцию: критичен Bundle ID.

## Состав организаций

Изменения согласуются в `OrganizationRegistry.swift` (порядок, source support, юридические реквизиты, hh IDs, trudvsem profiles), `employers.json` (HH defaults и verification metadata), `EmployerConfiguration.swift` (существующая миграция), `TrudvsemEmployerConfiguration.swift` (defaults и reconciliation), `FieldInstitutionClassifier.swift` (доказательства и независимые профили). Проверьте `OrganizationRegistry.key(forHH:)`, `supportsHH` и `available(on:)`.

Простая замена bundled JSON не означает удаление уже существующих пользовательских записей: store сохраняет их по своему контракту. Не используйте пользовательский контейнер для эксперимента. Не объявляйте непроверенный профиль подтверждённым. Обновите тематические unit fixtures, `scripts/verify_independence.py` (явный ожидаемый набор) и реестры в docs. Проверьте пустую выдачу, пользовательскую запись, старую конфигурацию, дубли/чужие реквизиты и фильтры обеих вкладок.

## Авторизация

Форк собирается и работает с уже встроенным токеном. Получение своего токена рекомендуется, но не требуется для запуска. Прочитайте [правила использования встроенного токена](../README.md#использование-встроенного-токена). После получения собственного токена замените `HHAuthConfig.appAccessToken` в `HHVacancyCBR/HHVacancyCBR/HHAuthConfig.swift` и пересоберите приложение. Не добавляйте значение в отчёты, README или диагностические логи. Не меняйте request pacing или создавайте массовый параллельный опрос с общим токеном. Процедура выдачи и численные квоты здесь не утверждаются.

## Новый источник

Сначала определите transport DTO/валидацию, полный сбор, pagination/limits/retry/cancellation, совместимое отдельное хранилище и evidence-контракт. Точки подключения: `VacancySource`, `OrganizationRegistry.available(on:)`, `AppComposition`, `ContentView`, собственные ViewModel/Views, `PDFSourceEvidence.capture` и проверка source при экспорте, `PDFExportWorker`, форматтер и статистика.

Сохраните явные различия API. Новое состояние не должно перезаписывать существующие snapshots или автоматически запускать сеть при переключении. Полные обновления проходят через общий `VacancyRefreshScheduler`; отказ от него — отдельное функциональное решение. Нужны fixtures для пустой/большой/повреждённой выдачи, дубликатов, лимитов, повторов, отмены, старых данных, трёх PDF, исходных bytes/hash и отсутствующих материалов. UI-проверки должны подтвердить независимость всех источников и сохранение после перезапуска. Этот рефакторинг нового источника не добавляет.

## Собственный CI и выпуск

Для изменений приложения выполните [полный набор проверок](TESTING.md), включая сборку из чистого коммита; при подготовке выпуска — локальный DMG в новый каталог. Для одной документации новая упаковка не нужна.

Проверьте workflow `macOS` в своём репозитории: `build-and-test`, `release-build` и `ui-tests` должны завершиться успешно для одного выбранного SHA. Обычные jobs используют ad hoc/отключённую подпись и не требуют Developer ID или секретов нотарификации. Живые API-тесты выключены; не добавляйте их flags в глобальное окружение CI. UI требует интерактивного macOS runner; текущий workflow рассчитан на `macos-15` и `arm64`.

Workflow `Release DMG` по тегу `v*` создаёт только артефакт Actions. `scripts/publish_release.py` переносит файлы только в локальный каталог. Для доступного пользователям установщика отдельно создайте GitHub Release **в своём форке**, приложите проверенные DMG и `.sha256`, скачайте их обратно и сравните байты. Подробный порядок — [RELEASING.md](RELEASING.md).

Проверьте существующие теги и выберите свободные версию/build и тег. Не перемещайте импортированные теги оригинала и не выдавайте его DMG за сборку своего коммита. В README форка замените ссылки на загрузки, подпись, требования и описание возможностей фактическими данными своего продукта. Встроенный токен разрешён на условиях выше; основной проект и Streebog имеют разные условия лицензирования.

Исторические отчёты `docs/archive/` и `docs/validation/` подтверждают указанные в них сборки HHVacancyCBR. Их локальные пути и готовые `.xctestrun` не являются переносимыми командами для форка. Сохраняйте собственные результаты в новых каталогах; не объявляйте чужой успешный CI проверкой вашего SHA.
