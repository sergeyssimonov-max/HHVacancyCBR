import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
struct MonitoringArchiveView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var to = Date()
    @State private var rows: [HistoricalVacancy] = []
    @State private var reports: [ArchiveManifest] = []
    @State private var employer = ""
    @State private var locality = ""
    @State private var fieldsOnly = false
    @State private var message = ""
    @State private var busy = false
    @State private var comparison = ""
    @State private var webCapture: HistoricalVacancy? = nil
    private var filtered: [HistoricalVacancy] {
        rows.filter { (ArchiveJSON.date($0.observation.receivedAt).map { $0 >= from && $0 <= to } ?? false) && (employer.isEmpty || $0.value.employerName.localizedCaseInsensitiveContains(employer) || $0.value.employerID == employer)
            && (locality.isEmpty || ($0.value.summary.area?.name ?? "").localizedCaseInsensitiveContains(locality))
            && (!fieldsOnly || $0.value.isFieldInstitution) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("История наблюдений и архив документов").font(.title2); Spacer(); Button("Закрыть") { dismiss() } }
            HStack { DatePicker("С", selection: $from); DatePicker("По", selection: $to); Button("Показать") { reload() }.disabled(busy || from > to) }
            HStack { TextField("Работодатель / ID", text: $employer); TextField("Местность", text: $locality); Toggle("Полевые учреждения", isOn: $fieldsOnly) }
            HStack { Text("Наблюдений вакансий: \(filtered.count)"); Spacer(); Button("Отчёт за период в PDF") { exportPeriod() }.disabled(busy || from > to) }
            List(filtered) { row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.value.name).font(.headline)
                    Text("\(row.value.employerName) · ID \(row.value.id) · \(row.observation.receivedAt)").font(.caption)
                    HStack { Button("Карточка наблюдения в PDF") { exportCard(row) }; Button("Сравнить с предыдущим") { compare(row) }; Button("Страница hh.ru") { webCapture = row } }.buttonStyle(.borderless)
                }
            }.frame(minHeight: 170)
            if !comparison.isEmpty { ScrollView { Text(comparison).textSelection(.enabled) }.frame(maxHeight: 100) }
            Text("Сохранённые документы").font(.headline)
            List(reports, id: \.report.id) { manifest in
                HStack {
                    VStack(alignment: .leading) { Text(manifest.report.kind); Text(manifest.report.createdAt + " · " + manifest.report.id).font(.caption).textSelection(.enabled) }
                    Spacer()
                    Button("PDF") { restore(manifest) }; Button("Проверить") { verify(manifest) }
                }.buttonStyle(.borderless)
            }.frame(minHeight: 130)
            Text(message).font(.caption).textSelection(.enabled)
            if busy { ProgressView() }
        }.padding(20).frame(minWidth: 1000, minHeight: 700).onAppear { reload() }.sheet(item: $webCapture) { row in VacancyWebCaptureView(observation: row.observation, vacancyID: row.value.id) }
    }
    private func destination(_ name: String, type: UTType) -> URL? {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.allowedContentTypes = [type]
        return panel.runModal() == .OK ? panel.url : nil
    }
    private func reload() {
        busy = true
        Task {
            do {
                let result = try await Task.detached { (try DocumentArchive.shared.history(), try DocumentArchive.shared.reports()) }.value
                rows = result.0; reports = result.1; message = ""
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    private func exportPeriod() {
        guard let url = destination("Мониторинг-за-период.pdf", type: .pdf) else { return }
        var report = VacancyStatisticsReport(entries: filtered.map { .init($0.value) }, modeName: "История наблюдений", employerID: "history",
            employerName: employer.isEmpty ? "Все работодатели" : employer, regionID: "history", regionName: locality.isEmpty ? "Все местности" : locality,
            createdAt: Date(), timeZoneIdentifier: TimeZone.current.identifier, sourceNote: "")
        report.periodFrom = from; report.periodTo = to; report.categoryName = fieldsOnly ? "Полевые учреждения" : "Все вакансии"
        let capturedReport = report
        busy = true
        Task { do { try await PDFExportWorker().exportStatistics(report: capturedReport, destination: url); reload() } catch { message = error.localizedDescription }; busy = false }
    }
    private func exportCard(_ row: HistoricalVacancy) {
        guard let url = destination("Наблюдение-\(row.observation.id).pdf", type: .pdf) else { return }
        let snapshot = PDFVacancySnapshot(value: row.value); busy = true
        Task { do { try await PDFExportWorker().exportPersonal(vacancy: snapshot, destination: url); reload() } catch { message = error.localizedDescription }; busy = false }
    }
    private func restore(_ manifest: ArchiveManifest) {
        guard let url = destination(manifest.report.id + ".pdf", type: .pdf) else { return }
        busy = true
        Task {
            do {
                try await Task.detached {
                    try DocumentArchive.shared.restore(id: manifest.report.id, destination: url)
                }.value
                message = "Сохранены первоначальные материалы документа"
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    private func verify(_ manifest: ArchiveManifest) {
        do { try DocumentArchive.shared.verify(DocumentArchive.shared.root.appendingPathComponent("reports/" + manifest.report.id)); message = "Целостность файлов подтверждена: " + manifest.report.id }
        catch { message = error.localizedDescription }
    }
    private func compare(_ row: HistoricalVacancy) {
        guard let previous = filtered.last(where: { $0.value.id == row.value.id && $0.observation.endpoint == row.observation.endpoint && $0.observation.receivedAt < row.observation.receivedAt }) else { comparison = "Предыдущее наблюдение в выбранном периоде отсутствует"; return }
        let values: [(String, String, String)] = [("Должность", previous.value.name, row.value.name), ("Работодатель", previous.value.employerName, row.value.employerName),
            ("Дата публикации hh.ru", previous.value.publishedAt ?? "", row.value.publishedAt ?? ""),
            ("Местность hh.ru", previous.value.summary.area?.name ?? "", row.value.summary.area?.name ?? ""),
            ("Зарплата", previous.value.salaryText ?? "", row.value.salaryText ?? ""),
            ("Опыт", previous.value.details.experience?.name ?? "", row.value.details.experience?.name ?? ""),
            ("Занятость", previous.value.details.employment?.name ?? "", row.value.details.employment?.name ?? ""),
            ("График", previous.value.details.schedule?.name ?? "", row.value.details.schedule?.name ?? ""),
            ("Статус", previous.value.archiveStatusText, row.value.archiveStatusText), ("Приём откликов", previous.value.applicationStatusText, row.value.applicationStatusText),
            ("Описание", previous.value.details.description ?? previous.value.summary.snippet?.plainText ?? "", row.value.details.description ?? row.value.summary.snippet?.plainText ?? "")]
        let changes = values.filter { $0.1 != $0.2 }.map { "\($0.0):\n\($0.1)\n→ \($0.2)" }
        comparison = previous.observation.receivedAt + " → " + row.observation.receivedAt + "\n" + (changes.isEmpty ? "Сравниваемые поля совпадают" : changes.joined(separator: "\n\n"))
    }
}

/// Optional real WebKit viewport capture; never draws an API response as a web page.
@MainActor
struct VacancyWebCaptureView: View {
    let observation: APIObservation
    let vacancyID: String
    @Environment(\.dismiss) private var dismiss
    @State private var browser = WKWebView(frame: .zero)
    @State private var message = ""
    var body: some View {
        VStack {
            HStack {
                Text("https://hh.ru/vacancy/" + vacancyID).textSelection(.enabled)
                Spacer()
                Button("Сохранить видимую страницу") { capture() }
                Button("Закрыть") { dismiss() }
            }.padding()
            WebCaptureSurface(browser: browser, vacancyID: vacancyID)
            Text(message).padding(8)
        }.frame(width: 1100, height: 800)
    }
    private func capture() {
        guard !browser.isLoading, let url = browser.url,
              url.scheme == "https", (url.host == "hh.ru" || url.host?.hasSuffix(".hh.ru") == true),
              url.path == "/vacancy/" + vacancyID else { message = "Дождитесь загрузки страницы вакансии hh.ru"; return }
        browser.takeSnapshot(with: nil) { image, error in
            guard let image, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
                message = error?.localizedDescription ?? "Не удалось получить снимок"; return
            }
            do {
                try DocumentArchive.shared.captureWeb(png: png, url: url, observationID: observation.id, vacancyID: vacancyID,
                                                     width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
                message = "Сохранён настоящий снимок видимой области WebKit"
            } catch { message = error.localizedDescription }
        }
    }
}
import WebKit
private struct WebCaptureSurface: NSViewRepresentable {
    let browser: WKWebView
    let vacancyID: String
    func makeNSView(context: Context) -> WKWebView {
        browser.load(URLRequest(url: URL(string: "https://hh.ru/vacancy/" + vacancyID)!)); return browser
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
