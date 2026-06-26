import SwiftUI
import AppKit

private enum ContentSheet: String, Identifiable {
    case help

    var id: String { rawValue }
}

/// A user-facing alert with its own title, so a Gemini quota / rate-limit error
/// reads as a distinct, actionable notice rather than a generic failure.
struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Owns all UI state and bridges the SwiftUI views to the Python helper.
@MainActor
final class AppViewModel: ObservableObject {
    @Published var selectedFolder: String?
    @Published var query: String = ""
    @Published var results: [SearchResult] = []
    @Published var indexSummary: IndexSummary?
    @Published var status: HelperStatus?
    @Published var modelInfo: ModelInfo?
    @Published var isIndexing = false
    @Published var indexProgress: IndexProgress?
    @Published var isSearching = false
    @Published var hasSearched = false
    @Published var scope: SearchScope = .auto
    @Published var detectedScopeLabel: String?   // what "auto" resolved to, for display
    @Published var indexedFiles: [IndexedFile] = []
    @Published var isLoadingFiles = false
    @Published var searchNotice: String?
    @Published var activeAlert: AppAlert?

    private let helper = HelperService()

    /// Turn a thrown error into a user-facing alert, giving the Gemini quota /
    /// rate-limit case a dedicated title so users know it's an API-limit issue.
    private func present(_ error: Error) {
        if let helperError = error as? HelperError, helperError.isQuotaExceeded {
            activeAlert = AppAlert(
                title: "Gemini API limit reached",
                message: helperError.localizedDescription
            )
        } else if let helperError = error as? HelperError, helperError.isNetworkUnavailable {
            activeAlert = AppAlert(
                title: "Gemini is unreachable",
                message: helperError.localizedDescription
            )
        } else {
            activeAlert = AppAlert(
                title: "Something went wrong",
                message: error.localizedDescription
            )
        }
    }

    func loadInitialState() async {
        await refreshStatus()
        await refreshFiles()
        modelInfo = try? await helper.getModelInfo()
    }

    func refreshStatus() async {
        // Best-effort: a failure here shouldn't surface as an error alert.
        status = try? await helper.getStatus()
    }

    func refreshFiles() async {
        isLoadingFiles = true
        defer { isLoadingFiles = false }
        indexedFiles = (try? await helper.listFiles()) ?? indexedFiles
    }

    func index(force: Bool = false) async {
        guard let folder = selectedFolder, !isIndexing else { return }
        isIndexing = true
        indexProgress = nil
        defer {
            isIndexing = false
            indexProgress = nil
        }
        do {
            indexSummary = try await helper.indexFolder(path: folder, force: force) { [weak self] progress in
                // Delivered off the main actor — hop back to update published state.
                Task { @MainActor in self?.indexProgress = progress }
            }
            await refreshStatus()
            await refreshFiles()
        } catch {
            present(error)
        }
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSearching else { return }
        isSearching = true
        hasSearched = true
        defer { isSearching = false }
        do {
            let outcome = try await helper.search(query: trimmed, scope: scope)
            results = outcome.results
            detectedScopeLabel = (scope == .auto)
                ? SearchScope.friendlyName(forResolved: outcome.resolvedScope)
                : nil
            searchNotice = nil
        } catch {
            if let helperError = error as? HelperError, helperError.isNetworkUnavailable {
                await runLocalSearchFallback(query: trimmed)
                return
            }
            present(error)
            results = []
            detectedScopeLabel = nil
            searchNotice = nil
        }
    }

    private func runLocalSearchFallback(query: String) async {
        do {
            let outcome = try await helper.localSearch(query: query, scope: scope)
            results = outcome.results
            detectedScopeLabel = nil
            searchNotice = outcome.message ?? "Offline: showing local filename/text matches"
        } catch {
            present(error)
            results = []
            detectedScopeLabel = nil
            searchNotice = nil
        }
    }

    func reset() async {
        do {
            try await helper.resetIndex()
            indexSummary = nil
            results = []
            hasSearched = false
            indexedFiles = []
            searchNotice = nil
            await refreshStatus()
        } catch {
            present(error)
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @AppStorage("resultViewMode") private var viewMode: ResultViewMode = .list
    @State private var showResetConfirm = false
    @State private var presentedSheet: ContentSheet?

    /// Keep the results screen active after the first submitted search.
    ///
    /// Tying this to the live query text rebuilt the surrounding view when the
    /// user cleared an old query and typed the first character of a new one,
    /// which caused the search field to lose focus after that character.
    private var isSearchActive: Bool {
        viewModel.hasSearched
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSearchActive {
                    SearchResultsView(
                        results: viewModel.results,
                        hasSearched: viewModel.hasSearched,
                        isSearching: viewModel.isSearching,
                        searchNotice: viewModel.searchNotice,
                        viewMode: viewMode
                    )
                } else {
                    IndexedFilesView(
                        files: viewModel.indexedFiles,
                        isLoading: viewModel.isLoadingFiles,
                        hasFolder: viewModel.selectedFolder != nil,
                        viewMode: viewMode
                    )
                }
            }
            .navigationTitle("Semantic File Finder")
            .navigationSubtitle(subtitle)
            .toolbar { toolbarContent }
            .onChange(of: viewModel.scope) {
                if isSearchActive { Task { await viewModel.search() } }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 10) {
                    SearchBar(
                        query: $viewModel.query,
                        scope: $viewModel.scope,
                        isSearching: viewModel.isSearching,
                        onSubmit: { Task { await viewModel.search() } }
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                    if viewModel.isIndexing {
                        IndexProgressBanner(progress: viewModel.indexProgress)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.bottom, viewModel.isIndexing ? 0 : 12)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(viewModel: viewModel)
            }
            .animation(.smooth(duration: 0.25), value: viewModel.isIndexing)
        }
        .frame(minWidth: 760, minHeight: 580)
        .task { await viewModel.loadInitialState() }
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .help:
                HelpView()
            }
        }
        .alert(
            viewModel.activeAlert?.title ?? "",
            isPresented: alertBinding,
            presenting: viewModel.activeAlert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .confirmationDialog(
            "Reset the index?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset Index", role: .destructive) { Task { await viewModel.reset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all indexed data. You'll need to index a folder again to search.")
        }
    }

    private var subtitle: String {
        guard let folder = viewModel.selectedFolder else { return "No folder chosen" }
        return URL(fileURLWithPath: folder).lastPathComponent
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.activeAlert != nil },
            set: { if !$0 { viewModel.activeAlert = nil } }
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                if let picked = chooseFolderPath() {
                    viewModel.selectedFolder = picked
                }
            } label: {
                Label("Choose Folder", systemImage: "folder.badge.plus")
            }
            .help("Choose a folder to index")

            Button {
                Task { await viewModel.index() }
            } label: {
                Label("Index", systemImage: "tray.and.arrow.down")
            }
            .disabled(viewModel.selectedFolder == nil || viewModel.isIndexing)
            .help("Index the selected folder")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if !viewModel.results.isEmpty || !viewModel.indexedFiles.isEmpty {
                Picker("View Mode", selection: $viewMode) {
                    ForEach(ResultViewMode.allCases) { mode in
                        Image(systemName: mode.systemImage)
                            .tag(mode)
                            .help(mode.label)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Show results as a list or icons")
            }

            Button {
                presentedSheet = .help
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .help("Learn how Semantic File Finder works")

            Menu {
                Button {
                    Task { await viewModel.index(force: true) }
                } label: {
                    Label("Re-index (force)", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.selectedFolder == nil || viewModel.isIndexing)

                if let folder = viewModel.selectedFolder {
                    Button {
                        FileActions.reveal(folder)
                    } label: {
                        Label("Reveal Folder in Finder", systemImage: "folder")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("Reset Index…", systemImage: "trash")
                }
                .disabled(viewModel.isIndexing)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More actions")
        }
    }
}

/// A Finder-style bottom status bar: the indexed folder, result count, and stats.
private struct StatusBar: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            if let folder = viewModel.selectedFolder {
                Text(folder)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            } else {
                Text("No folder selected")
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            if viewModel.hasSearched && !viewModel.results.isEmpty {
                if let notice = viewModel.searchNotice {
                    Label(notice, systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                } else if viewModel.scope == .auto, let detected = viewModel.detectedScopeLabel {
                    Label("Auto: \(detected)", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                }
                Text("\(viewModel.results.count) result\(viewModel.results.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                if !indexStatsText.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                }
            }
            if !indexStatsText.isEmpty {
                Text(indexStatsText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var indexStatsText: String {
        var parts: [String] = []
        if let status = viewModel.status, status.status == "success" {
            parts.append("\(status.totalFiles ?? 0) files · \(status.totalChunks ?? 0) chunks indexed")
        }
        if let model = viewModel.modelInfo, model.status == "success", let name = model.embeddingModel {
            parts.append(name + (model.textOnlyMode == true ? " · text-only" : ""))
        }
        return parts.joined(separator: "  ·  ")
    }
}

#Preview {
    ContentView()
}
