import SwiftUI

enum WindowLayoutPolicy {
    static let minimumSize = CGSize(width: 900, height: 560)
    static let defaultSize = CGSize(width: 960, height: 680)
}

struct ContentView: View {
    @ObservedObject var viewModel: VacancySearchViewModel
    @StateObject private var trudvsem = AppComposition.makeTrudvsemViewModel()
    @State private var source: VacancySource = .hh
    var body: some View {
        Group {
            if source == .hh {
                VacancySearchViews.MainWindow(viewModel: viewModel, refresh: { viewModel.startRefresh() }, source: $source)
            } else {
                TrudvsemViews(viewModel: trudvsem, source: $source)
            }
        }
        .frame(minWidth: WindowLayoutPolicy.minimumSize.width, minHeight: WindowLayoutPolicy.minimumSize.height)
        .task { await viewModel.loadPersistenceIfNeeded(); trudvsem.load() }
    }
}
