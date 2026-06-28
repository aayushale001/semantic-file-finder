import SwiftUI
import AppKit

/// The default "gallery" shown when nothing is being searched: every distinct
/// file in the index, rendered in the same list / icon layouts as search results.
struct IndexedFilesView: View {
    let files: [IndexedFile]
    let isLoading: Bool
    let hasFolder: Bool
    let roots: [String]
    let viewMode: ResultViewMode

    /// Show the originating folder only when more than one is watched.
    private var showsRoot: Bool { roots.count > 1 }

    private func rootLabel(for path: String) -> String? {
        showsRoot ? RootResolver.displayName(for: path, among: roots) : nil
    }

    var body: some View {
        Group {
            if files.isEmpty {
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
            if isLoading && files.isEmpty {
                ProgressView().controlSize(.large)
            }
        }
        .animation(.smooth(duration: 0.2), value: viewMode)
        .animation(.smooth(duration: 0.2), value: files)
    }

    @ViewBuilder
    private var emptyState: some View {
        if hasFolder {
            ContentUnavailableView(
                "Nothing indexed yet",
                systemImage: "tray",
                description: Text("Click Index All in the toolbar to add watched folders' files — text, PDFs, code, images, audio, and video.")
            )
        } else {
            ContentUnavailableView(
                "Add a folder to begin",
                systemImage: "folder.badge.plus",
                description: Text("Add one or more folders and index them; your files appear here, ready to search by meaning.")
            )
        }
    }

    private var listView: some View {
        List(files) { file in
            IndexedFileRow(file: file, rootLabel: rootLabel(for: file.filePath))
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        }
        .listStyle(.inset)
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 16)],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(files) { file in
                    IndexedFileCard(file: file, rootLabel: rootLabel(for: file.filePath))
                }
            }
            .padding(16)
        }
    }
}

// MARK: - List row

struct IndexedFileRow: View {
    let file: IndexedFile
    var rootLabel: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Thumbnail(path: file.filePath, ext: file.fileExtension, size: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(file.fileName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if let rootLabel {
                        RootBadge(name: rootLabel)
                    }
                    ModalityBadge(modality: file.modality)
                }

                Text(file.filePath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 10) {
                    Text("\(file.chunkCount) chunk\(file.chunkCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Open") { FileActions.open(file.filePath) }
                        .buttonStyle(.link)
                    Button("Reveal") { FileActions.reveal(file.filePath) }
                        .buttonStyle(.link)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu { OpenRevealButtons(path: file.filePath) }
    }
}

// MARK: - Icon grid card

struct IndexedFileCard: View {
    let file: IndexedFile
    var rootLabel: String? = nil
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Thumbnail(path: file.filePath, ext: file.fileExtension, size: 92)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                Text(file.fileName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let rootLabel {
                    RootBadge(name: rootLabel)
                }

                HStack(spacing: 6) {
                    ModalityBadge(modality: file.modality)
                    Spacer()
                    Text("\(file.chunkCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .help("\(file.chunkCount) indexed chunk\(file.chunkCount == 1 ? "" : "s")")
                }
            }
        }
        .padding(12)
        .frame(height: 188, alignment: .top)
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
        .onTapGesture(count: 2) { FileActions.open(file.filePath) }
        .contextMenu { OpenRevealButtons(path: file.filePath) }
        .help(file.filePath)
    }
}

// MARK: - Shared

/// A small capsule showing a file's modality (image / audio / video / text / …).
struct ModalityBadge: View {
    let modality: String

    var body: some View {
        Text(modality.capitalized)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.gray.opacity(0.18)))
            .foregroundStyle(.secondary)
    }
}
