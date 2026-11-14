import SwiftUI

@main
struct HHVacancyCBRApp: App {
    @StateObject private var viewModel: VacancySearchViewModel

    init() { _viewModel = StateObject(wrappedValue: AppComposition.makeViewModel()) }

    var body: some Scene {
        Window("ЦБВакансии", id: "main") { ContentView(viewModel: viewModel) }
            .defaultSize(width: WindowLayoutPolicy.defaultSize.width, height: WindowLayoutPolicy.defaultSize.height)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
