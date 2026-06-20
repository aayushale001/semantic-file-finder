import Foundation

/// One search hit, decoded from the helper's `search` JSON.
struct SearchResult: Codable, Identifiable, Equatable {
    let id = UUID()
    let fileName: String
    let filePath: String
    let fileExtension: String
    let contentPreview: String
    let pageNumber: Int?
    let chunkIndex: Int
    let score: Double?

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case filePath = "file_path"
        case fileExtension = "file_extension"
        case contentPreview = "content_preview"
        case pageNumber = "page_number"
        case chunkIndex = "chunk_index"
        case score
    }
}

/// Wrapper for the `search` command response.
struct SearchResponse: Codable {
    let status: String
    let query: String?
    let results: [SearchResult]?
    let message: String?
}

/// Response from the `index` command.
struct IndexSummary: Codable {
    let status: String
    let indexedFiles: Int?
    let skippedFiles: Int?
    let indexedChunks: Int?
    let errors: [String]?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case status
        case indexedFiles = "indexed_files"
        case skippedFiles = "skipped_files"
        case indexedChunks = "indexed_chunks"
        case errors
        case message
    }
}

/// Response from the `status` command.
struct HelperStatus: Codable {
    let status: String
    let totalChunks: Int?
    let totalFiles: Int?
    let dbPath: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case status
        case totalChunks = "total_chunks"
        case totalFiles = "total_files"
        case dbPath = "db_path"
        case message
    }
}

/// Response from the `model-info` command.
struct ModelInfo: Codable {
    let status: String
    let embeddingProvider: String?
    let embeddingModel: String?
    let embeddingDimensions: Int?
    let textOnlyMode: Bool?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case status
        case embeddingProvider = "embedding_provider"
        case embeddingModel = "embedding_model"
        case embeddingDimensions = "embedding_dimensions"
        case textOnlyMode = "text_only_mode"
        case message
    }
}

// MARK: - Indexing progress (streamed)

/// A single progress update derived from the `index --progress` NDJSON stream.
struct IndexProgress: Equatable {
    let current: Int          // files fully processed so far
    let total: Int            // total files to process
    let fileName: String?     // the file just processed (nil for the start event)
    let indexedFiles: Int
    let skippedFiles: Int
    let indexedChunks: Int
    let segmentCurrent: Int?  // sub-progress within a media file (e.g. frame k…)
    let segmentTotal: Int?    // …of m

    /// Completion in 0…1, including sub-progress within the current file.
    var fraction: Double {
        guard total > 0 else { return 0 }
        var done = Double(current)
        if let total = segmentTotal, total > 0, let current = segmentCurrent {
            done += min(1, Double(current) / Double(total))
        }
        return min(1, max(0, done / Double(total)))
    }

    /// 1-based index of the file being worked on (vs. one fully completed).
    var displayFileIndex: Int {
        segmentTotal != nil ? min(total, current + 1) : current
    }

    /// Files still to process.
    var remaining: Int { max(0, total - current) }
}

/// One line of the `index --progress` NDJSON stream. Every line is one of:
/// a `start`/`progress` event, the final `complete` summary, or an error object.
struct IndexStreamLine: Decodable {
    let event: String?
    let status: String?
    let message: String?
    // progress fields
    let current: Int?
    let total: Int?
    let fileName: String?
    let segmentCurrent: Int?
    let segmentTotal: Int?
    // summary fields
    let indexedFiles: Int?
    let skippedFiles: Int?
    let indexedChunks: Int?
    let errors: [String]?

    enum CodingKeys: String, CodingKey {
        case event, status, message, current, total, errors
        case fileName = "file_name"
        case segmentCurrent = "segment_current"
        case segmentTotal = "segment_total"
        case indexedFiles = "indexed_files"
        case skippedFiles = "skipped_files"
        case indexedChunks = "indexed_chunks"
    }

    /// The terminal summary line (`complete`), or a single-object summary if the
    /// helper ever falls back to non-streaming output.
    var isComplete: Bool { event == "complete" || (event == nil && status != nil) }
    var isError: Bool { status == "error" }

    func asProgress() -> IndexProgress {
        IndexProgress(
            current: current ?? 0,
            total: total ?? 0,
            fileName: fileName,
            indexedFiles: indexedFiles ?? 0,
            skippedFiles: skippedFiles ?? 0,
            indexedChunks: indexedChunks ?? 0,
            segmentCurrent: segmentCurrent,
            segmentTotal: segmentTotal
        )
    }

    func asSummary() -> IndexSummary {
        IndexSummary(
            status: status ?? "success",
            indexedFiles: indexedFiles,
            skippedFiles: skippedFiles,
            indexedChunks: indexedChunks,
            errors: errors,
            message: message
        )
    }
}

// MARK: - Results view mode

/// How the results area renders: a detailed list, or a Finder-style icon grid.
enum ResultViewMode: String, CaseIterable, Identifiable {
    case list
    case icons

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: return "List"
        case .icons: return "Icons"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .icons: return "square.grid.2x2"
        }
    }
}

// MARK: - Indexed files (the default "gallery" view)

/// One distinct file in the index, decoded from the helper's `list` command.
struct IndexedFile: Codable, Identifiable, Equatable {
    var id: String { filePath }
    let filePath: String
    let fileName: String
    let fileExtension: String
    let modality: String
    let chunkCount: Int
    let fileSizeBytes: Int?
    let fileModifiedAt: String?
    let indexedAt: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case fileName = "file_name"
        case fileExtension = "file_extension"
        case modality
        case chunkCount = "chunk_count"
        case fileSizeBytes = "file_size_bytes"
        case fileModifiedAt = "file_modified_at"
        case indexedAt = "indexed_at"
    }
}

/// Wrapper for the `list` command response.
struct ListFilesResponse: Codable {
    let status: String
    let files: [IndexedFile]?
    let message: String?
}

// MARK: - Search scope

/// Restricts a search to one kind of file. Sidesteps the text/media "modality
/// gap" — without it, text documents out-rank images/audio/video in a mixed list.
enum SearchScope: String, CaseIterable, Identifiable {
    case all, documents, images, audio, video

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .documents: return "Documents"
        case .images: return "Images"
        case .audio: return "Audio"
        case .video: return "Video"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .documents: return "doc.text"
        case .images: return "photo"
        case .audio: return "music.note"
        case .video: return "film"
        }
    }
}
