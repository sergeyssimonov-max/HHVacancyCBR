import SwiftUI
import WebKit

enum VacancySearchViews {
    struct MainWindow: View {
        @ObservedObject var viewModel: VacancySearchViewModel
        let refresh: () -> Void
        @Binding var source: VacancySource

        private enum ToolbarMetrics {
            static let controlHeight: CGFloat = 32
            static let modeWidth: CGFloat = 220
        }

        var body: some View {
            VStack(spacing: 0) {
                toolbar
                HStack {
                    TextField("Поиск в названии и описании", text: $viewModel.searchText)
                        .textFieldStyle(.roundedBorder)
                    Picker("Сортировка", selection: $viewModel.sort) {
                        ForEach(VacancySort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.frame(width: 230)
                }.padding(.horizontal, 20).padding(.vertical, 8)
                Divider()
                statusBar
                Divider()
                if let warning = viewModel.snapshotWarning { warningView(warning) }
                if let warning = viewModel.collectionWarning {
                    warningView(warning)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("collectionWarning")
                }
                content
            }
            .background(DeskPalette.content)
        }

        private var toolbar: some View {
            HStack(spacing: 14) {
                Picker("", selection: $source) {
                    Text("hh.ru").tag(VacancySource.hh)
                    Text("trudvsem.ru").tag(VacancySource.trudvsem)
                }
                .pickerStyle(.segmented)
                .frame(width: ToolbarMetrics.modeWidth, height: ToolbarMetrics.controlHeight)
                .accessibilityIdentifier("vacancyListModePicker")

                Picker("Категория", selection: $viewModel.fieldInstitutionsOnly) {
                    Text("Все вакансии").tag(false)
                    Text("Полевые учреждения").tag(true)
                }
                .labelsHidden()
                .frame(width: 190, height: ToolbarMetrics.controlHeight)
                .accessibilityIdentifier("categoryFilterPicker")

                Picker("Работодатель", selection: $viewModel.selectedEmployerID) {
                    ForEach(viewModel.employerFilterOptions) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .frame(minWidth: 140, maxWidth: .infinity)
                .frame(height: ToolbarMetrics.controlHeight)
                .accessibilityIdentifier("employerFilterPicker")

                Picker("Субъект", selection: $viewModel.selectedRegionID) {
                    ForEach(viewModel.regionFilterOptions) { Text($0.title).tag($0.id) }
                }
                .labelsHidden()
                .frame(minWidth: 140, maxWidth: .infinity)
                .frame(height: ToolbarMetrics.controlHeight)
                .accessibilityIdentifier("regionFilterPicker")

                Group {
                    VacancyRefreshButton(title: refreshButtonTitle) {
                        if viewModel.isLoading { viewModel.cancelSearch() } else { refresh() }
                    }
                    .disabled(viewModel.isLoading ? !viewModel.canCancelSearch : !viewModel.canSearch)
                    .help(viewModel.isLoading ? "Остановить загрузку; сохранится предыдущая полная выборка" : "Обновить выборку вакансий")
                    .accessibilityIdentifier("searchVacanciesButton")
                }
            }
            .controlSize(.large)
            // Match the status bar and cards; native button insets vary by macOS version.
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            .background(DeskPalette.toolbar)
        }

        private var refreshButtonTitle: String {
            guard viewModel.isLoading else { return "Обновить" }
            return viewModel.isCancellingSearch ? "Отмена…" : "Отменить"
        }

        private var bulkExportTitle: String {
            guard viewModel.isExportingBulkPDF else { return "Все вакансии в PDF" }
            return viewModel.isCancellingBulkPDFExport ? "Отмена…" : "Отменить экспорт"
        }

        @ViewBuilder private var content: some View {
            if viewModel.isLoading && viewModel.displayedResults.isEmpty {
                VacancyEmptyState(message: "Загружаем вакансии всех настроенных работодателей…", isLoading: true)
            } else if let error = viewModel.errorMessage, viewModel.displayedResults.isEmpty {
                empty(title: "Не удалось загрузить вакансии", message: error)
            } else if viewModel.hasSearched && viewModel.displayedResults.isEmpty {
                empty(title: "Вакансий не найдено", message: viewModel.emptyResultsMessage)
            } else if !viewModel.hasSearched && viewModel.displayedResults.isEmpty {
                VacancyEmptyState(message: "Загрузите вакансии hh.ru кнопкой «Обновить».")
            } else {
                results
            }
        }

        private var statusBar: some View {
            HStack(spacing: 12) {
                VacancyStatusSummary(
                    vacancyCountMessage: viewModel.displayedVacancyCountMessage,
                    fieldInstitutionCount: viewModel.displayedResults.filter(\.isFieldInstitution).count,
                    updatedAtMessage: viewModel.updatedAtMessage,
                    loadingEmployerName: viewModel.isLoading ? viewModel.currentEmployerName : nil)
                Spacer()
                Group {
                    PDFExportCommand(title: bulkExportTitle) {
                        if viewModel.isExportingBulkPDF {
                            viewModel.cancelBulkPDFExport()
                        } else {
                            viewModel.startBulkPDFExport()
                        }
                    }.disabled(viewModel.isExportingBulkPDF
                        ? !viewModel.canCancelBulkPDFExport
                        : !viewModel.canExportBulkPDF)
                        .accessibilityIdentifier("exportBulkPDFButton")
                }
                PDFExportCommand(title: viewModel.isExportingStatisticsPDF ? "Сохранение…" : "Статистика в PDF") {
                    Task { await viewModel.exportStatisticsPDF() }
                }
                .disabled(!viewModel.canExportStatisticsPDF)
                .help("Сохранить статистику и список вакансий под текущими фильтрами")
                .accessibilityIdentifier("exportStatisticsPDFButton")
            }
            .lineLimit(1)
            .font(.system(size: 13))
            .foregroundColor(.secondary)
            .padding(.leading, 28)
            .padding(.trailing, 28)
            .frame(height: 48)
        }

        private var results: some View {
            VStack(spacing: 0) {
                if let error = viewModel.errorMessage { warningView(error) }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.displayedResults) { result in
                            VacancyCard(
                                result: result,
                                isExpanded: viewModel.expandedVacancyID == result.id,
                                toggleDetails: { viewModel.toggleExplanation(for: result.id) },
                                openURL: { viewModel.openVacancyURL(id: result.id) },
                                copyURL: { viewModel.copyVacancyURL(id: result.id) },
                                exportPDF: { await viewModel.exportVacancyPDF(id: result.id) }
                            )
                            Divider()
                        }
                    }
                }
            }
        }

        private func warningView(_ text: String) -> some View {
            HStack { Label(text, systemImage: "exclamationmark.triangle"); Spacer() }
                .font(.caption).foregroundColor(.secondary).padding(.horizontal, 28).padding(.vertical, 10)
        }

        private func empty(title: String, message: String) -> some View {
            VStack(spacing: 12) {
                Text(title).font(.headline)
                Text(message).foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
private struct VacancyCard: View {
    let result: VacancySearchResult
    let isExpanded: Bool
    let toggleDetails: () -> Void
    let openURL: () -> Void
    let copyURL: () -> Bool
    let exportPDF: () async -> Bool
    @State private var copied = false
    @State private var exported = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(result.name)
                            .font(.system(size: 15, weight: .semibold))
                            .accessibilityIdentifier("vacancyTitle.\(result.id)")
                        if result.isArchived { Label("В архиве", systemImage: "archivebox").font(.caption) }
                    }
                    if result.isFieldInstitution {
                        Text("Полевое учреждение").font(.caption).foregroundColor(.secondary)
                            .help(result.fieldInstitution.reason ?? "")
                            .accessibilityIdentifier("fieldInstitutionBadge.\(result.id)")
                    }
                    Text(result.employerName).font(.system(size: 13)).foregroundColor(.secondary)
                    if let department = result.departmentName { Text(department).font(.caption).foregroundColor(.secondary) }
                }
                Spacer()
                VacancyCompensationSummary(salary: result.salaryText, area: result.areaName)
            }
            HStack(spacing: 10) {
                Button("Открыть на hh.ru ↗", action: openURL).disabled(result.alternateURL == nil)
                Button(copied ? "✓ Скопировано" : "Скопировать ссылку") { if copyURL() { copied = true } }.disabled(result.alternateURL == nil)
                Button(isExpanded ? "Скрыть детали" : "Подробнее", action: toggleDetails)
                    .accessibilityIdentifier("expandVacancy.\(result.id)")
                Spacer()
                PDFExportCommand(title: exported ? "✓ Сохранено" : "Экспорт в PDF", action: {
                    Task {
                        if await exportPDF() {
                            exported = true
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            exported = false
                        }
                    }
                }).disabled(exported)
                    .accessibilityIdentifier("exportVacancyPDF.\(result.id)")
            }.buttonStyle(.borderless)
            if isExpanded { details }
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if result.isDetailLoading {
                Label("Загружаем полное описание…", systemImage: "hourglass")
            } else if let error = result.detailErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
            } else if result.hasFullDescription {
                VacancyHTMLDescriptionView(html: result.htmlDescription).frame(minHeight: 320)
            } else {
                Text("Полное описание вакансии отсутствует.").foregroundColor(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VacancyHTMLDocument {
    static func make(from bodyHTML: String) -> String {
        let body = VacancyHTMLAttributedText.sanitize(bodyHTML)
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root{color-scheme:light dark} body{margin:14px;font:-apple-system-body;color:-apple-system-label;background:transparent;overflow-wrap:anywhere}
        a{color:-apple-system-link} img,table{max-width:100%;height:auto}
        </style></head><body>\(body)</body></html>
        """
    }
}

struct VacancyHTMLDescriptionView: NSViewRepresentable {
    let html: String
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration); view.navigationDelegate = context.coordinator; view.underPageBackgroundColor = .clear; return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        // Match SwiftUI even when appearance is overridden locally; CSS updates without reloading.
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(VacancyHTMLDocument.make(from: html), baseURL: nil)
    }
    // Keep the async delegate signature on both SDK generations. Xcode 15 imports
    // this requirement as nonisolated; Xcode 16 adds main-actor isolation in WebKit.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?
        #if compiler(>=6.0)
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.request.url?.scheme == "about" { return .allow }
            if action.navigationType == .linkActivated, let url = action.request.url,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
        #else
        nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.request.url?.scheme == "about" { return .allow }
            if action.navigationType == .linkActivated, let url = action.request.url,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                _ = await MainActor.run { NSWorkspace.shared.open(url) }
            }
            return .cancel
        }
        #endif
    }
}
