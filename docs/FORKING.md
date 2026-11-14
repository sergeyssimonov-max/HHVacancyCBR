# Независимый форк

Рефакторинг сохраняет идентичность текущего продукта. Шаги ниже выполняет автор нового варианта, а не оригинальное приложение. Перед публичным распространением необходимо решение владельца о лицензии основного проекта: разрешение использовать встроенный токен не заменяет лицензию на код. Сторонняя лицензия Streebog находится в `HHVacancyCBR/HHVacancyCBR/Vendor/Streebog/LICENSE`.

Все короткие имена Swift-файлов и `Assets.xcassets` ниже отсчитываются от `HHVacancyCBR/HHVacancyCBR/`. Команды выполняются из корня.

## Получение и обновление исходников

Создайте fork средствами GitHub, затем используйте адрес своего репозитория вместо примера:

```sh
git clone https://github.com/YOUR_ACCOUNT/HHVacancyCBR.git
cd HHVacancyCBR
git remote add upstream https://github.com/sergeyssimonov-max/HHVacancyCBR.git
git fetch upstream
```

Проверьте `git status`, выполните исходные тесты. Перед получением изменений сохраните собственную работу отдельным коммитом. `git fetch upstream` не меняет файлы; сравните `git log --oneline HEAD..upstream/main` и `git diff HEAD...upstream/main`, затем применяйте выбранные изменения или `git merge upstream/main`, разрешая конфликты по смыслу. Не копируйте целиком настройки оригинала поверх новой идентичности. Повторите проверки после merge. Уважайте AGENTS.md своего форка; он должен явно описывать принятый порядок работы.

## Состав организаций

Изменения согласуются в `OrganizationRegistry.swift` (порядок, source support, юридические реквизиты, hh IDs, trudvsem profiles), `employers.json` (HH defaults и verification metadata), `EmployerConfiguration.swift` (существующая миграция), `TrudvsemEmployerConfiguration.swift` (defaults и reconciliation), `FieldInstitutionClassifier.swift` (доказательства и независимые профили). Проверьте `OrganizationRegistry.key(forHH:)`, `supportsHH` и `available(on:)`.

Простая замена bundled JSON не означает удаление уже существующих пользовательских записей: store сохраняет их по своему контракту. Не используйте пользовательский контейнер для эксперимента. Не объявляйте непроверенный профиль подтверждённым. Обновите тематические unit fixtures, `scripts/verify_independence.py` (явный ожидаемый набор) и реестры в docs. Проверьте пустую выдачу, пользовательскую запись, старую конфигурацию, дубли/чужие реквизиты и фильтры обеих вкладок.

## Идентичность и параллельная установка

Выберите собственные bundle ID, название и storage directory. В `HHVacancyCBR/HHVacancyCBR.xcodeproj/project.pbxproj` согласованно измените PRODUCT_BUNDLE_IDENTIFIER основного приложения и тестовых targets, PRODUCT_NAME, product references, paths, TEST_HOST/TEST_TARGET_NAME, Info.plist-настройки, entitlements paths и схему в `HHVacancyCBR/HHVacancyCBR.xcodeproj/xcshareddata/xcschemes/HHVacancyCBR.xcscheme`. При переименовании targets обновите все CLI/CI selectors.

В `HHVacancyCBRApp.swift` задайте заголовок окна, в Assets.xcassets/AppIcon.appiconset — собственную иконку. `HHVacancyCBR/Scripts/render_icon.py` генерирует иконку текущего продукта, его входные обозначения тоже требуют проверки. В `ApplicationSupportLocation.swift` замените `directoryName`; собственный bundle ID создаст отдельный sandbox-контейнер. Не направляйте новый продукт в старый контейнер и не добавляйте автоматическое копирование данных оригинала.

Согласуйте префиксы `HHVACANCYCBR_` в AppComposition и тестах, temporary directory prefixes в fixtures и `PDFSourceEvidence`, имена ресурсов и артефактов. Найдите оставшиеся упоминания через `rg -n 'HHVacancyCBR|HHVACANCYCBR|ЦБВакансии|local.sergey' HHVacancyCBR scripts .github README.md docs`. Не делайте слепую замену внутри пользовательских данных, JSON keys, исходных API identifiers или стороннего кода.

В `scripts/release.sh`, `scripts/publish_release.py`, Python-тестах, CI/release workflows и `scripts/verify_release_entitlements.py` проверьте product path, имена DMG, bundle IDs и подпись. `verify_independence.py` должен защищать новую идентичность, а не просто перестать проверять старую. Обновите opt-in UI проверки установленного приложения: их `/Applications` target обязан указывать на форк. В документации и README замените ссылки на origin/releases.

После сборки установите оригинал и форк рядом, проверьте разные bundle IDs, разные контейнеры, обновление/перезапуск каждого и сохранность обоих наборов данных. Ни название окна, ни другое имя `.app` сами по себе не обеспечивают изоляцию: критичен bundle ID. Identity исходного HHVacancyCBR в данном рефакторинге не менялась.

## Авторизация

Форк собирается и работает с уже встроенным токеном. Получение своего токена рекомендуется, но не требуется для запуска. Прочитайте [правила использования встроенного токена](../README.md#использование-встроенного-токена). После получения собственного токена замените `HHAuthConfig.appAccessToken` в `HHVacancyCBR/HHVacancyCBR/HHAuthConfig.swift` и пересоберите приложение. Не добавляйте значение в отчёты, README или диагностические логи. Не меняйте request pacing или создавайте массовый параллельный опрос с общим токеном. Процедура выдачи и численные квоты здесь не утверждаются.

## Новый источник

Сначала определите transport DTO/валидацию, полный сбор, pagination/limits/retry/cancellation, совместимое отдельное хранилище и evidence-контракт. Точки подключения: `VacancySource`, `OrganizationRegistry.available(on:)`, `AppComposition`, `ContentView`, собственные ViewModel/Views, `PDFSourceEvidence.capture` и проверка source при экспорте, `PDFExportWorker`, форматтер и статистика.

Сохраните явные различия API. Новое состояние не должно перезаписывать существующие snapshots или автоматически запускать сеть при переключении. Полные обновления проходят через общий `VacancyRefreshScheduler`; отказ от него — отдельное функциональное решение. Нужны fixtures для пустой/большой/повреждённой выдачи, дубликатов, лимитов, повторов, отмены, старых данных, трёх PDF, исходных bytes/hash и отсутствующих материалов. UI-проверки должны подтвердить независимость всех источников и сохранение после перезапуска. Этот рефакторинг нового источника не добавляет.

Для каждого перечисленного изменения выполняйте [полный набор проверок](TESTING.md), включая clean build и локальный DMG в новый каталог без публикации.
