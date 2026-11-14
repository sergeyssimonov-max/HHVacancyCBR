# Локальные runtime-проверки

Этот harness компилируется с production Swift-кодом в `-O`. HH заменён actor-fixture: ни один режим не обращается к сети. Не запускайте production load test.

```sh
benchmark_dir=$(mktemp -d /private/tmp/HHVacancyCBR-benchmark.XXXXXX)
bash scripts/benchmarks/build.sh "$benchmark_dir/benchmark"
"$benchmark_dir/benchmark" reliability
"$benchmark_dir/benchmark" gate 100
"$benchmark_dir/benchmark" enrichment-cancel 100
"$benchmark_dir/benchmark" enrichment-limit 100
"$benchmark_dir/benchmark" enrichment-repeat 100
"$benchmark_dir/benchmark" search 200
"$benchmark_dir/benchmark" pdf 10
"$benchmark_dir/benchmark" pdf 100
"$benchmark_dir/benchmark" pdf 500
"$benchmark_dir/benchmark" stress 1
"$benchmark_dir/benchmark" statistics 2000
"$benchmark_dir/benchmark" soak 500
```

Для текущего `search` используйте не более 200 вакансий. Фикстура этого harness возвращает одну и ту же выдачу для основного и дополнительного поиска полевых учреждений. При 1 000 записях дополнительный поиск достигает действующего предела двух страниц, сборщик правильно отмечает неполноту, а `precondition` harness о полной выборке завершается `SIGTRAP`. Это воспроизводится и до рефакторинга; фикстура и рабочий алгоритм здесь не исправлялись. `search 200` проверяет четыре запроса (две основные и две дополнительные страницы). Большие выборки и разбиение свыше 2 000 результатов отдельно покрывает XCTest.

Используйте положительное число вакансий. `stress` создаёт 1 200 HTML-абзацев на вакансию; остальные PDF-режимы — 12. `pdf` включает подготовку, валидацию и реальную transaction-публикацию. `statistics` включает atomic write, повторное открытие и проверку присутствия последнего входного ID. `soak` создаёт шесть статистических PDF с безопасными суффиксами. `enrichment-*` проверяет подготовку ViewModel, а не рендер: exporter-spy фиксирует вызовы и возвращает отмену выбора каталога. В `enrichment-repeat` два последовательных экспорта. `search` проверяет сборщик на локальной постраничной фикстуре. Живая сеть для этих режимов запрещена.

Вывод — JSON: wall-clock, CPU user+system (`getrusage`), peak RSS в байтах (macOS), текущий RSS через `ps` в KiB, число открытых дескрипторов из первых 1 024, страницы и размер файлов. `resident_kib: -1` означает, что sandbox запретил `ps`; это не отрицательное потребление памяти. Проверка heartbeat main actor включает накладные расходы самого harness (в том числе PDFKit extraction и `ps`); это не измерение задержки отрисовки SwiftUI. В PDF-режимах параллельно выполняются 20 лёгких mock detail-операций. Более прикладной сценарий фильтры + details + PDF покрыт unit integration-тестом.

Для сравнения собирайте before/after одним toolchain и запускайте не менее пяти раз в одинаковой среде разрешений. Не смешивайте sandbox и unrestricted: на macOS 13 доступ к font registry меняет даже layout/размер PDF. Не запускайте сборки и UI-тесты параллельно с timed benchmark. Короткие wall-clock-замеры чувствительны к scheduler и фоновой нагрузке; надёжнее точные request counts, semantic checks и scaling.

Каждый запуск создаёт собственный UUID-каталог и удаляет его после штатного завершения, включая transaction recovery directories, созданные только этим synthetic workload. Сам бинарник и module-cache остаются в выбранном `benchmark_dir`: после работы удалите именно этот проверенный каталог. После аварийного завершения проверьте собственный `HHRuntimeBench-*` каталог перед удалением. Не удаляйте пользовательские PDF recovery directories.

Для визуальной проверки задайте `HH_BENCH_PREVIEW=/absolute/scratch/preview.pdf` режиму `statistics`: указанный scratch-файл будет заменён копией отчёта. Затем используйте `pdftoppm`. Не указывайте существующий пользовательский документ.

Режим `reliability` запускает автономные проверки production-кода без службы XCTest: общий Retry-After между клиентами, отмена URL-запроса и очереди обновления, остановка при 401/403/429, ограничения страниц и времени, сохранение текста при пагинации, PDF-ссылки, три режима PDF trudvsem.ru и отказ при повреждении исходного ответа. Использует только синтетические ответы и виртуальное время; к живым API не обращается.

## Детерминированное сравнение PDF при рефакторинге

`PDFEquivalence.swift` формирует индивидуальный, статистический и массовый PDF каждого источника, два пустых статистических отчёта и массовый экспорт одной карточки из 6 500 абзацев через границу 100 страниц. Все данные синтетические; сетевых запросов нет. Исходные ответы, их UUID, время получения, локаль и часовой пояс фиксированы. Архив создаётся только в собственном временном каталоге standalone-процесса и удаляется по завершении.

Существующий production-код самостоятельно вызывает `Date()` в заголовках. Для сравнения без изменения этого кода `FixtureClock.c` подменяет только `CFAbsoluteTimeGetCurrent` внутри тестового процесса через `DYLD_INSERT_LIBRARIES`. Harness проверяет, что время действительно фиксировано; системные часы, монотонное время и установленное приложение не затрагиваются. Эта библиотека не входит в Xcode targets и не поставляется в приложении.

```sh
comparison_dir=$(mktemp -d /private/tmp/HHVacancyCBR-equivalence.XXXXXX)
# baseline_sources — каталог HHVacancyCBR/HHVacancyCBR в сохранённой исходной копии.
bash scripts/benchmarks/build_pdf_equivalence.sh "$comparison_dir/before" "${baseline_sources:?Укажите каталог исходной версии}"
TZ=UTC LC_ALL=en_US.UTF-8 DYLD_INSERT_LIBRARIES="$comparison_dir/fixture-clock.dylib" \
  "$comparison_dir/before" "$comparison_dir/before-artifacts" -AppleLocale en_US_POSIX -AppleLanguages '(en)'
# После преобразования собрать тем же toolchain, в том же окружении.
bash scripts/benchmarks/build_pdf_equivalence.sh "$comparison_dir/after"
TZ=UTC LC_ALL=en_US.UTF-8 DYLD_INSERT_LIBRARIES="$comparison_dir/fixture-clock.dylib" \
  "$comparison_dir/after" "$comparison_dir/after-artifacts" -AppleLocale en_US_POSIX -AppleLanguages '(en)'
python3 scripts/benchmarks/compare_pdf_equivalence.py \
  "$comparison_dir/before-artifacts" "$comparison_dir/after-artifacts"
```

Каталоги артефактов должны быть новыми: существующие файлы не перезаписываются. `manifest.json` содержит точный извлечённый текст и порядок документов, число страниц/частей, хеши RGBA-растров всех страниц, исходные вложения в base64 и их Streebog-512, имена файлов, локаль и фиксированное время. Сравнение ничего не нормализует и не удаляет значимые даты. Весь PDF не сравнивается побайтно: CoreGraphics может менять служебные идентификаторы и упаковку объектов при одинаковом документе. Дополнительно просмотрите PDF и сохранённые PNG первых/последних страниц. Не запускайте сравнение с другой конфигурацией шрифтов или разрешений — она может изменить layout независимо от исходного кода.

## Фильтрация обеих ViewModel на одинаковых данных

`FilterBenchmarks.swift` загружает настоящие форматы снимков во `VacancySearchViewModel` и `TrudvsemViewModel`, затем проверяет пустую выборку и заданное число синтетических вакансий. Для сравнения используйте 10 000. В каждом наборе 12 сценариев: вся отсортированная выдача, работодатель, регион, неизвестный регион, AND работодателя и региона, поиск по описанию с другим регистром и краевыми пробелами, поиск по заголовку, поиск вместе с AND-фильтрами, полевые учреждения, все фильтры вместе, отсутствие совпадений и очистка поиска. Фикстуры содержат повторяющиеся заголовки/даты, записи без даты и разные организации; независимый oracle по исходным метаданным проверяет весь порядок ID, включая tie-break по ID.

Даты публикации, дата снимка, часы HH ViewModel и raw payload фиксированы. Время операций измеряется монотонным `systemUptime`. Настоящие API-клиенты заменены rejecting spy: даже попытка обращения считается ошибкой; итоговый `networkCallCount` должен быть нулём. Снимки и локальная конфигурация trudvsem.ru создаются только в собственном `HHFilterBench-<UUID>` временном каталоге и удаляются после запуска. Harness также проверяет, что фильтрация не переписала снимки. PDF и архивы исходных API-ответов не создаются; пользовательские контейнеры не используются.

```sh
filter_dir=$(mktemp -d /private/tmp/HHVacancyCBR-filter.XXXXXX)
# baseline_sources — HHVacancyCBR/HHVacancyCBR из сохранённой исходной копии.
bash scripts/benchmarks/build_filter_benchmarks.sh "$filter_dir/before" "${baseline_sources:?Укажите каталог исходной версии}"
bash scripts/benchmarks/build_filter_benchmarks.sh "$filter_dir/after"
for revision in before after; do
  for run in 1 2 3 4 5; do
    TZ=UTC LC_ALL=en_US.UTF-8 "$filter_dir/$revision" 10000 \
      -AppleLocale en_US_POSIX -AppleLanguages '(en)' > "$filter_dir/$revision-$run.json"
  done
done
```

Сначала сравните `fixtureSHA256`, `trudRawPayloadSHA256`, число результатов и оба ID digest каждого сценария во всех десяти JSON: они должны точно совпадать до/после. `logicalIDsSHA256` дополнительно одинаков у HH и trudvsem.ru, а `nativeIDsSHA256` сохраняет собственный формат ID источника. Затем сравните медиану пяти `filterWallSeconds`, `filterCPUSeconds`, `cachedReadWallSeconds` и `processPeakRSSBytes`; загрузка снимков измеряется отдельно. `maximumSynchronousFilterSeconds` показывает длительность синхронного вычисления `displayedResults` на main actor, а не задержку отрисовки SwiftUI. Peak RSS относится ко всему процессу, включая создание/загрузку фикстур, и не является отдельным расходом памяти одного фильтра. Сборки, другие benchmark и UI-тесты во время timed-прогонов не запускайте.

Проверяйте также фактические `locale` и `timeZone` в JSON: macOS может сохранить системную локаль, несмотря на launch arguments. Во всех сравниваемых запусках значения должны совпадать. Пустой явно переданный baseline-путь отклоняется до компиляции.
