import SwiftUI
import AppKit

private enum ContentSheet: String, Identifiable {
    case help
    case settings

    var id: String { rawValue }
}

/// A user-facing alert with its own title, so a Gemini quota / rate-limit error
/// reads as a distinct, actionable notice rather than a generic failure.
struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Outcome of saving a Keychain API key. A temporary Gemini failure must be
/// visibly different from an invalid key: the former is still safely saved.
enum APIKeySaveResult {
    case verified
    case savedButUnverified(String)
    case failed(String)
}

/// Owns all UI state and bridges the SwiftUI views to the Python helper.
@MainActor
final class AppViewModel: ObservableObject {
    /// Watched folders that make up the index. Persisted across launches.
    @Published var roots: [String] = []
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
    @Published var isLoadingFiles = true
    @Published var fileListError: String?
    @Published var searchNotice: String?
    @Published var activeAlert: AppAlert?
    /// Whether this app build can read a saved Gemini key without showing
    /// Keychain permission UI.
    @Published var hasStoredAPIKey = KeychainStore.hasAPIKey()
    /// A transient "auto-syncing changes…" hint while the watcher re-indexes.
    @Published var isAutoSyncing = false

    private let helper = HelperService()
    private let watcher = FolderWatcher()

    /// One queued indexing request. Indexing is serialized through `pendingJobs`
    /// so manual re-index and watcher-triggered syncs never overlap.
    private struct IndexJob: Equatable {
        let path: String
        let force: Bool
        let background: Bool
    }
    private var pendingJobs: [IndexJob] = []
    private var indexingActive = false

    private static let rootsKey = "indexedRoots"

    init() {
        let savedRoots = UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? []
        roots = Self.uniqueNormalizedPaths(savedRoots)
        if roots != savedRoots {
            saveRoots()
        }
        watcher.onChange = { [weak self] changed in
            // FolderWatcher delivers on the main queue; hop onto the main actor.
            Task { @MainActor in self?.handleWatchEvent(changed) }
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func uniqueNormalizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for raw in paths {
            let path = normalizedPath(raw)
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            unique.append(path)
        }
        return unique
    }

    private func saveRoots() {
        UserDefaults.standard.set(roots, forKey: Self.rootsKey)
    }

    private func startWatching() {
        watcher.start(paths: roots)
    }

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
        // The three startup reads are independent one-shot subprocesses, so run
        // them concurrently: the slowest helper call controls startup instead
        // of paying the three process launches sequentially.
        isLoadingFiles = true
        fileListError = nil
        defer { isLoadingFiles = false }
        async let filesTask = helper.listFiles()
        async let statusTask = helper.getStatus()
        async let modelTask = helper.getModelInfo()
        do {
            indexedFiles = try await filesTask
        } catch {
            fileListError = error.localizedDescription
        }
        status = try? await statusTask
        modelInfo = try? await modelTask
        startWatching()
    }

    func refreshStatus() async {
        // Best-effort: a failure here shouldn't surface as an error alert.
        status = try? await helper.getStatus()
    }

    func refreshFiles() async {
        isLoadingFiles = true
        fileListError = nil
        defer { isLoadingFiles = false }
        do {
            indexedFiles = try await helper.listFiles()
        } catch {
            fileListError = error.localizedDescription
        }
    }

    // MARK: Gemini API key (bring-your-own-key)

    /// True when there is already something useful to show on the home screen.
    /// This keeps existing offline/indexed-file browsing from being covered by
    /// first-run key setup.
    var hasIndexedContent: Bool {
        !indexedFiles.isEmpty || (status?.totalFiles ?? 0) > 0
    }

    /// Save `key` to the Keychain, restart the helper so it picks the key up,
    /// and validate it with a lightweight metadata call. Only an explicit
    /// invalid-key response removes the saved key; offline and quota failures
    /// leave it safely stored for a later retry.
    func saveAPIKey(_ key: String) async -> APIKeySaveResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Paste your Gemini API key first.") }
        guard KeychainStore.saveAPIKey(trimmed) else {
            hasStoredAPIKey = KeychainStore.hasAPIKey()
            return .failed("Could not save the key to the macOS Keychain.")
        }
        hasStoredAPIKey = true
        await helper.restartServer()
        do {
            try await helper.checkAPIKey()
        } catch {
            if let helperError = error as? HelperError, helperError.isInvalidAPIKey {
                let removed = KeychainStore.deleteAPIKey()
                hasStoredAPIKey = KeychainStore.hasAPIKey()
                await helper.restartServer()
                modelInfo = try? await helper.getModelInfo()
                if removed {
                    return .failed(helperError.localizedDescription)
                }
                return .failed(
                    "\(helperError.localizedDescription) The rejected key could not be removed from Keychain; use Remove Key before trying another one."
                )
            }
            modelInfo = try? await helper.getModelInfo()
            return .savedButUnverified(
                "Key saved, but Gemini could not verify it right now. It will be used when Gemini is reachable. \(error.localizedDescription)"
            )
        }
        modelInfo = try? await helper.getModelInfo()
        return .verified
    }

    func removeAPIKey() async {
        _ = KeychainStore.deleteAPIKey()
        hasStoredAPIKey = KeychainStore.hasAPIKey()
        await helper.restartServer()
        modelInfo = try? await helper.getModelInfo()
    }

    // MARK: Watched folders

    /// Pick a folder, start watching it, and index it.
    func addFolder() {
        guard let picked = chooseFolderPath() else { return }
        let path = Self.normalizedPath(picked)
        guard !roots.contains(path) else { return }
        roots.append(path)
        saveRoots()
        startWatching()
        enqueueIndex([IndexJob(path: path, force: false, background: false)])
    }

    /// Stop watching a folder and drop its files from the index.
    func removeFolder(_ path: String) async {
        let previousRoots = roots
        roots.removeAll { $0 == path }
        saveRoots()
        startWatching()
        do {
            try await helper.removeFolder(path: path)
        } catch {
            roots = previousRoots
            saveRoots()
            startWatching()
            present(error)
        }
        await refreshStatus()
        await refreshFiles()
    }

    /// Re-index every watched folder (manual "Index All").
    func indexAll(force: Bool = false) {
        enqueueIndex(roots.map { IndexJob(path: $0, force: force, background: false) })
    }

    // MARK: File-watching → incremental sync

    private func handleWatchEvent(_ changed: Set<String>) {
        enqueueIndex(changed.map { IndexJob(path: $0, force: false, background: true) })
    }

    private func enqueueIndex(_ jobs: [IndexJob]) {
        for job in jobs {
            if let existing = pendingJobs.firstIndex(where: { $0.path == job.path }) {
                // Merge with the queued job for this path so a forced or
                // user-initiated request is never dropped by a background sync
                // that happened to be queued first.
                pendingJobs[existing] = IndexJob(
                    path: job.path,
                    force: pendingJobs[existing].force || job.force,
                    background: pendingJobs[existing].background && job.background
                )
            } else {
                pendingJobs.append(job)
            }
        }
        Task { await drainIndexQueue() }
    }

    /// Serially process queued indexing jobs so manual and background runs
    /// never overlap (one Python subprocess and one DB writer at a time).
    private func drainIndexQueue() async {
        guard !indexingActive else { return }
        indexingActive = true
        isIndexing = true
        defer {
            indexingActive = false
            isIndexing = false
            isAutoSyncing = false
            indexProgress = nil
            // A watcher event can arrive while the final status/file refreshes
            // are suspended. Its initial drain task sees `indexingActive` and
            // returns, so explicitly schedule a new pass after releasing the
            // gate rather than leaving that work stranded.
            if !pendingJobs.isEmpty {
                Task { @MainActor [weak self] in
                    await self?.drainIndexQueue()
                }
            }
        }
        while !pendingJobs.isEmpty {
            let job = pendingJobs.removeFirst()
            isAutoSyncing = job.background
            await runIndex(job)
        }
        await refreshStatus()
        await refreshFiles()
    }

    private func runIndex(_ job: IndexJob) async {
        indexProgress = nil
        do {
            indexSummary = try await helper.indexFolder(
                path: job.path, force: job.force, prune: true
            ) { [weak self] progress in
                // Delivered off the main actor — hop back to update published state.
                Task { @MainActor in self?.indexProgress = progress }
            }
        } catch {
            // Background syncs shouldn't nag: offline / quota errors are expected
            // and will clear on their own. Surface only user-initiated failures.
            if !job.background { present(error) }
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

    func returnHome() {
        query = ""
        results = []
        hasSearched = false
        detectedScopeLabel = nil
        searchNotice = nil
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
                        roots: viewModel.roots,
                        viewMode: viewMode
                    )
                } else {
                    IndexedFilesView(
                        files: viewModel.indexedFiles,
                        isLoading: viewModel.isLoadingFiles,
                        hasFolder: !viewModel.roots.isEmpty,
                        hasIndexedContent: viewModel.hasIndexedContent,
                        loadError: viewModel.fileListError,
                        roots: viewModel.roots,
                        viewMode: viewMode
                    )
                }
            }
            .navigationTitle("Fosvera")
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
                        onSubmit: { Task { await viewModel.search() } },
                        onClear: { viewModel.returnHome() }
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
                .animation(.smooth(duration: 0.25), value: viewModel.isIndexing)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                StatusBar(viewModel: viewModel)
            }
        }
        .frame(minWidth: 760, minHeight: 580)
        .task {
            await viewModel.loadInitialState()
            // First run: no key and nothing indexed yet — walk the user through
            // setup. If files are already indexed, keep the file-manager-style
            // home gallery visible; Settings remains available from the toolbar.
            if viewModel.modelInfo?.hasApiKey == false && !viewModel.hasIndexedContent {
                presentedSheet = .settings
            }
        }
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .help:
                HelpView()
            case .settings:
                SettingsView(viewModel: viewModel)
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
        switch viewModel.roots.count {
        case 0: return "No folders watched"
        case 1: return URL(fileURLWithPath: viewModel.roots[0]).lastPathComponent
        default: return "\(viewModel.roots.count) folders watched"
        }
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
                viewModel.addFolder()
            } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }
            .help("Add a folder to watch and index")

            Menu {
                if viewModel.roots.isEmpty {
                    Text("No folders watched yet")
                } else {
                    ForEach(viewModel.roots, id: \.self) { root in
                        Menu(URL(fileURLWithPath: root).lastPathComponent) {
                            Button {
                                FileActions.reveal(root)
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                            Button(role: .destructive) {
                                Task { await viewModel.removeFolder(root) }
                            } label: {
                                Label("Stop Watching & Remove", systemImage: "minus.circle")
                            }
                        }
                    }
                }
            } label: {
                Label("Folders", systemImage: "folder")
            }
            .help("Watched folders")

            Button {
                viewModel.indexAll()
            } label: {
                Label("Index All", systemImage: "tray.and.arrow.down")
            }
            .disabled(viewModel.roots.isEmpty || viewModel.isIndexing)
            .help("Re-index every watched folder")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if isSearchActive {
                Button {
                    viewModel.returnHome()
                } label: {
                    Label("Home", systemImage: "house")
                }
                .help("Back to indexed files")
            }

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
                presentedSheet = .settings
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Set up your Gemini API key")

            Button {
                presentedSheet = .help
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .help("Learn how Fosvera works")

            Menu {
                Button {
                    viewModel.indexAll(force: true)
                } label: {
                    Label("Re-index All (force)", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.roots.isEmpty || viewModel.isIndexing)

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
            Image(systemName: viewModel.roots.isEmpty ? "folder" : "folder.fill.badge.gearshape")
                .foregroundStyle(.secondary)
            if viewModel.roots.isEmpty {
                Text("No folders watched")
                    .foregroundStyle(.tertiary)
            } else {
                Text(foldersSummary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }

            if viewModel.isAutoSyncing {
                Text("·").foregroundStyle(.tertiary)
                Label("Syncing changes…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
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

    private var foldersSummary: String {
        if viewModel.roots.count == 1 {
            return viewModel.roots[0]
        }
        let names = viewModel.roots.map { URL(fileURLWithPath: $0).lastPathComponent }
        return "\(viewModel.roots.count) folders · " + names.joined(separator: ", ")
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
