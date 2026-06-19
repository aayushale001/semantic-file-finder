import SwiftUI
import AppKit
import QuickLookThumbnailing

/// The results area. Renders either a detailed list or a Finder-style icon grid,
/// with empty states for "not searched yet" and "no matches".
struct SearchResultsView: View {
    let results: [SearchResult]
    let hasSearched: Bool
    let isSearching: Bool
    let viewMode: ResultViewMode

    var body: some View {
        Group {
            if results.isEmpty {
                emptyState
            } else {
                switch viewMode {
                case .list: listView
                case .icons: gridView
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isSearching && results.isEmpty {
                ProgressView("Searching…")
                    .controlSize(.large)
                    .padding(24)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
        .animation(.smooth(duration: 0.2), value: viewMode)
        .animation(.smooth(duration: 0.2), value: results)
    }

    // MARK: Empty states

    @ViewBuilder
    private var emptyState: some View {
        if hasSearched {
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("Try a different query, or index more folders.")
            )
        } else {
            ContentUnavailableView(
                "Search your files by meaning",
                systemImage: "sparkles",
                description: Text("Choose a folder, index it, then type a natural-language query.")
            )
        }
    }

    // MARK: List

    private var listView: some View {
        List(results) { result in
            ResultRow(result: result)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        }
        .listStyle(.inset)
    }

    // MARK: Icon grid

    private var gridView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 16)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(results) { result in
                    ResultCard(result: result)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - List row

/// A single result row: icon, name, score, preview, path, and inline actions.
struct ResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Thumbnail(path: result.filePath, ext: result.fileExtension, size: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(result.fileName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let page = result.pageNumber {
                        Text("· p.\(page)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    if let score = result.score {
                        ScoreBadge(score: score)
                    }
                }

                Text(result.contentPreview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 10) {
                    Text(result.filePath)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Open") { FileActions.open(result.filePath) }
                        .buttonStyle(.link)
                    Button("Reveal") { FileActions.reveal(result.filePath) }
                        .buttonStyle(.link)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu { OpenRevealButtons(path: result.filePath) }
    }
}

// MARK: - Icon grid card

/// A Finder-style tile: large colored icon, file name, preview, and a score badge.
struct ResultCard: View {
    let result: SearchResult
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Thumbnail(path: result.filePath, ext: result.fileExtension, size: 46)
                Spacer()
                if let score = result.score {
                    ScoreBadge(score: score)
                }
            }

            Text(result.fileName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(result.contentPreview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            if let page = result.pageNumber {
                Label("page \(page)", systemImage: "doc.text")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(height: 176, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovering ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                              lineWidth: hovering ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(hovering ? 0.14 : 0.05),
                radius: hovering ? 7 : 2, y: hovering ? 3 : 1)
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.snappy(duration: 0.14), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { FileActions.open(result.filePath) }
        .contextMenu { OpenRevealButtons(path: result.filePath) }
        .help(result.filePath)
    }
}

// MARK: - Shared components

/// A rounded, color-coded file-type glyph (Finder-like), reused by row and card.
struct FileIcon: View {
    let ext: String
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: color.opacity(0.35), radius: 1, y: 0.5)
    }

    private var symbol: String {
        switch ext.lowercased() {
        case ".pdf": return "doc.richtext"
        case ".md", ".txt": return "doc.text"
        case ".docx": return "doc.text.fill"
        case ".jpg", ".jpeg", ".png": return "photo"
        case ".mp3", ".wav": return "music.note"
        case ".mp4", ".mov": return "film"
        case ".py", ".js", ".ts", ".tsx", ".jsx", ".cpp", ".c", ".h",
             ".hpp", ".java", ".html", ".css", ".json":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    private var color: Color {
        switch ext.lowercased() {
        case ".pdf": return .red
        case ".md", ".txt": return .gray
        case ".docx": return .blue
        case ".jpg", ".jpeg", ".png": return .green
        case ".mp3", ".wav": return .pink
        case ".mp4", ".mov": return .orange
        case ".py", ".js", ".ts", ".tsx", ".jsx", ".cpp", ".c", ".h",
             ".hpp", ".java", ".html", ".css", ".json":
            return .purple
        default: return .gray
        }
    }
}

/// A QuickLook content thumbnail (images / video / PDF) with a `FileIcon` fallback.
struct Thumbnail: View {
    let path: String
    let ext: String
    var size: CGFloat = 46

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: size * 0.18))
            } else {
                FileIcon(ext: ext, size: size)
            }
        }
        .task(id: path) {
            guard Self.isThumbnailable(ext) else { return }
            let url = URL(fileURLWithPath: path)
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: size, height: size),
                scale: scale,
                representationTypes: .thumbnail
            )
            image = try? await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request).nsImage
        }
    }

    static func isThumbnailable(_ ext: String) -> Bool {
        switch ext.lowercased() {
        case ".jpg", ".jpeg", ".png", ".mp4", ".mov", ".pdf": return true
        default: return false
        }
    }
}

/// A small capsule showing the match score as a percentage.
struct ScoreBadge: View {
    let score: Double

    var body: some View {
        Text(percent)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
            .help("Match score")
    }

    private var percent: String {
        let clamped = min(1, max(0, score))
        return "\(Int((clamped * 100).rounded()))%"
    }
}

/// The standard Open / Reveal / Copy-Path actions, used in context menus.
struct OpenRevealButtons: View {
    let path: String

    var body: some View {
        Button { FileActions.open(path) } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }
        Button { FileActions.reveal(path) } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        Divider()
        Button { FileActions.copyPath(path) } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }
    }
}

/// Thin wrappers over AppKit file actions.
enum FileActions {
    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
