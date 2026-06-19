import SwiftUI
import AppKit

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
    @Published var indexedFiles: [IndexedFile] = []
    @Published var isLoadingFiles = false
    @Published var errorMessage: String?

    private let helper = HelperService()

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
            errorMessage = error.localizedDescription
        }
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSearching else { return }
        isSearching = true
        hasSearched = true
        defer { isSearching = false }
        do {
            results = try await helper.search(query: trimmed)
        } catch {
            errorMessage = error.localizedDescription
            results = []
        }
    }

    func reset() async {
        do {
            try await helper.resetIndex()
            indexSummary = nil
            results = []
            hasSearched = false
            indexedFiles = []
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @AppStorage("resultViewMode") private var viewMode: ResultViewMode = .list
    @State private var showResetConfirm = false

    /// Show search results once a query has been run; otherwise the indexed-files gallery.
    private var isSearchActive: Bool {
        !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && viewModel.hasSearched
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSearchActive {
                    SearchResultsView(
                        results: viewModel.results,
                        hasSearched: viewModel.hasSearched,
                        isSearching: viewModel.isSearching,
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
            .searchable(
                text: $viewModel.query,
                placement: .toolbar,
                prompt: "Search files by meaning…"
            )
            .onSubmit(of: .search) { Task { await viewModel.search() } }
            .safeAreaInset(edge: .top, spacing: 0) {
                if viewModel.isIndexing {
                    IndexProgressBanner(progress: viewModel.indexProgress)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(viewModel: viewModel)
            }
            .animation(.smooth(duration: 0.25), value: viewModel.isIndexing)
        }
        .frame(minWidth: 760, minHeight: 580)
        .task { await viewModel.loadInitialState() }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
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

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
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
