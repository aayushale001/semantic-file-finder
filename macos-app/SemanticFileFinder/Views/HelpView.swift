import SwiftUI

/// A concise, in-app guide to the indexing and semantic-search workflow.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    workflow
                    howSearchWorks
                    supportedFiles
                    privacyNote
                }
                .padding(28)
            }

            Divider()

            HStack {
                Text("Tip: describe what you remember, not necessarily the filename.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 680)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 32))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text("How Semantic File Finder Works")
                    .font(.title2.weight(.semibold))

                Text("Search your files by meaning instead of exact names.")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(22)
    }

    private var workflow: some View {
        HelpSection(title: "Getting started", systemImage: "1.circle.fill") {
            VStack(spacing: 18) {
                HelpStep(
                    number: 1,
                    title: "Add one or more folders",
                    detail: "Select the folders containing the documents and media you want to search."
                )
                HelpStep(
                    number: 2,
                    title: "Index their files",
                    detail: "The app reads supported files, splits long content into manageable pieces, and creates an embedding for each piece. Watched folders auto-sync when files change."
                )
                HelpStep(
                    number: 3,
                    title: "Describe what you want",
                    detail: "Try natural phrases such as “meeting notes about the launch,” “people smiling,” or “instrumental music.”"
                )
                HelpStep(
                    number: 4,
                    title: "Open the best match",
                    detail: "Results are ranked by semantic similarity. Use Open or Reveal to access a matched file in Finder."
                )
            }
        }
    }

    private var howSearchWorks: some View {
        HelpSection(title: "What happens behind the scenes", systemImage: "brain.head.profile") {
            VStack(alignment: .leading, spacing: 12) {
                HelpFact(
                    systemImage: "sparkles",
                    title: "Gemini creates embeddings",
                    detail: "Text and supported media are converted into numerical representations of their meaning."
                )
                HelpFact(
                    systemImage: "externaldrive",
                    title: "LanceDB stores the index locally",
                    detail: "The generated vectors and searchable metadata live in a database on your Mac."
                )
                HelpFact(
                    systemImage: "scope",
                    title: "Scopes improve relevance",
                    detail: "Auto chooses a likely file kind, while Documents, Images, Audio, and Video let you narrow the search yourself."
                )
                HelpFact(
                    systemImage: "folder.badge.gearshape",
                    title: "Watched folders stay in sync",
                    detail: "You can add multiple folders. When files are added, changed, moved, or deleted, the app queues a background re-index and prunes stale results."
                )
                HelpFact(
                    systemImage: "wifi.slash",
                    title: "Offline falls back to local search",
                    detail: "If Gemini cannot be reached, searches use local filename, path, and indexed text matches. Indexing and semantic search resume when internet is back."
                )
            }
        }
    }

    private var supportedFiles: some View {
        HelpSection(title: "Supported files", systemImage: "doc.on.doc") {
            VStack(alignment: .leading, spacing: 8) {
                FileTypeRow(label: "Documents", types: "TXT, Markdown, PDF, DOCX")
                FileTypeRow(label: "Code", types: "Python, JavaScript, TypeScript, C/C++, Java, HTML, CSS, JSON")
                FileTypeRow(label: "Images", types: "JPG, JPEG, PNG")
                FileTypeRow(label: "Audio", types: "MP3, WAV")
                FileTypeRow(label: "Video", types: "MP4, MOV")
            }
        }
    }

    private var privacyNote: some View {
        HelpSection(title: "Data and privacy", systemImage: "lock.shield") {
            Text(
                "Your search index is stored locally. File content or media is sent to the configured Gemini API when embeddings are created, and search text is sent when a query is embedded."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HelpSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 14))
    }
}

private struct HelpStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.tint, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct HelpFact: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 22)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct FileTypeRow: View {
    let label: String
    let types: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.callout.weight(.medium))
                .frame(width: 82, alignment: .leading)
            Text(types)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

#Preview {
    HelpView()
}
