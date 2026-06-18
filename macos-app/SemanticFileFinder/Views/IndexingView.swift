import SwiftUI

/// A transient banner shown at the top of the window while indexing runs.
/// Shows a determinate progress bar with "current of total" and the file in flight.
struct IndexProgressBanner: View {
    let progress: IndexProgress?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeating)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title)
                            .font(.callout.weight(.semibold))
                        Spacer()
                        if let progress, progress.total > 0 {
                            Text("\(progress.current) of \(progress.total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    progressBar

                    if let detail = detailText {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
        }
        .background(.regularMaterial)
    }

    private var title: String {
        guard let progress else { return "Preparing to index…" }
        if progress.total == 0 { return "Scanning folder…" }
        return progress.remaining == 0 ? "Finishing up…" : "Indexing files…"
    }

    @ViewBuilder
    private var progressBar: some View {
        if let progress, progress.total > 0 {
            ProgressView(value: progress.fraction)
                .animation(.smooth(duration: 0.25), value: progress.fraction)
        } else {
            // Scanning: we don't know the count yet, so show an indeterminate bar.
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    private var detailText: String? {
        guard let progress else { return nil }
        var parts: [String] = []
        if let name = progress.fileName { parts.append(name) }
        if progress.indexedFiles > 0 || progress.skippedFiles > 0 {
            parts.append("\(progress.indexedFiles) indexed · \(progress.skippedFiles) skipped")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "   •   ")
    }
}
