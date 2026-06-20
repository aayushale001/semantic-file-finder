import Foundation

enum HelperError: LocalizedError {
    case helperNotFound(String)
    case pythonNotFound
    case processFailed(String)
    case decodingFailed(String)
    case helperReturnedError(String)

    var errorDescription: String? {
        switch self {
        case .helperNotFound(let path):
            return "Python helper not found at \(path). Set SEMANTIC_HELPER_DIR or the helperDirectory default."
        case .pythonNotFound:
            return "Could not find a Python interpreter (looked for the project .venv and /usr/bin/python3)."
        case .processFailed(let message):
            return "Helper failed: \(message)"
        case .decodingFailed(let message):
            return "Could not read helper output: \(message)"
        case .helperReturnedError(let message):
            return message
        }
    }
}

/// Runs the Python helper CLI as a subprocess and decodes its JSON output.
///
/// stdout is parsed as JSON; stderr is used only for error reporting. The two
/// pipes are drained concurrently so a chatty stderr can never deadlock a large
/// stdout (or vice versa).
final class HelperService {
    /// Directory containing `main.py`. Override at runtime with the
    /// `SEMANTIC_HELPER_DIR` env var or a `helperDirectory` UserDefaults key.
    static let defaultHelperDirectory =
        "/Users/aayushale/Desktop/VectorBasedFileSearch/helper"

    var helperDirectory: String {
        ProcessInfo.processInfo.environment["SEMANTIC_HELPER_DIR"]
            ?? UserDefaults.standard.string(forKey: "helperDirectory")
            ?? Self.defaultHelperDirectory
    }

    private var mainScript: String {
        (helperDirectory as NSString).appendingPathComponent("main.py")
    }

    // MARK: - Public API

    /// Index `path`. Pass `onProgress` to receive live per-file updates (the
    /// helper is run with `--progress` and its NDJSON is streamed); omit it for a
    /// single final summary. Progress callbacks are delivered off the main actor.
    func indexFolder(
        path: String,
        force: Bool = false,
        onProgress: (@Sendable (IndexProgress) -> Void)? = nil
    ) async throws -> IndexSummary {
        var args = ["index", path]
        if force { args.append("--force") }

        let summary: IndexSummary
        if let onProgress {
            args.append("--progress")
            summary = try await runIndexStreaming(args, onProgress: onProgress)
        } else {
            summary = try await run(args, as: IndexSummary.self)
        }

        if summary.status != "success" {
            throw HelperError.helperReturnedError(summary.message ?? "Indexing failed")
        }
        return summary
    }

    func search(query: String, limit: Int = 10, scope: SearchScope = .auto) async throws -> SearchOutcome {
        let response = try await run(
            ["search", query, "--limit", String(limit), "--scope", scope.rawValue],
            as: SearchResponse.self
        )
        if response.status != "success" {
            throw HelperError.helperReturnedError(response.message ?? "Search failed")
        }
        return SearchOutcome(
            results: response.results ?? [],
            resolvedScope: response.resolvedScope
        )
    }

    func getStatus() async throws -> HelperStatus {
        try await run(["status"], as: HelperStatus.self)
    }

    func listFiles() async throws -> [IndexedFile] {
        let response = try await run(["list"], as: ListFilesResponse.self)
        if response.status != "success" {
            throw HelperError.helperReturnedError(response.message ?? "Listing files failed")
        }
        return response.files ?? []
    }

    func getModelInfo() async throws -> ModelInfo {
        try await run(["model-info"], as: ModelInfo.self)
    }

    func resetIndex() async throws {
        let response = try await run(["reset"], as: HelperStatus.self)
        if response.status != "success" {
            throw HelperError.helperReturnedError(response.message ?? "Reset failed")
        }
    }

    // MARK: - Process plumbing

    private func run<T: Decodable>(_ args: [String], as type: T.Type) async throws -> T {
        let data = try await runRaw(args)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let text = String(data: data, encoding: .utf8) ?? "<non-utf8 output>"
            throw HelperError.decodingFailed("\(error.localizedDescription)\nOutput: \(text)")
        }
    }

    private func runRaw(_ args: [String]) async throws -> Data {
        let (process, outPipe, errPipe) = try makeProcess(args)
        try launch(process)

        // Drain both pipes concurrently, then wait for exit.
        async let stdoutData = readToEnd(outPipe.fileHandleForReading)
        async let stderrData = readToEnd(errPipe.fileHandleForReading)
        let out = await stdoutData
        let err = await stderrData
        process.waitUntilExit()

        if out.isEmpty {
            let errText = String(data: err, encoding: .utf8) ?? ""
            let detail = errText.isEmpty ? "no output (exit code \(process.terminationStatus))" : errText
            throw HelperError.processFailed(detail)
        }
        return out
    }

    /// Runs the helper and reads its stdout as NDJSON, one JSON object per line.
    /// `progress`/`start` lines are forwarded to `onProgress`; the terminal
    /// `complete` line is returned as the summary. stderr is drained concurrently
    /// so a chatty log stream can never deadlock the pipe.
    private func runIndexStreaming(
        _ args: [String],
        onProgress: @escaping @Sendable (IndexProgress) -> Void
    ) async throws -> IndexSummary {
        let (process, outPipe, errPipe) = try makeProcess(args)
        try launch(process)

        async let stderrData = readToEnd(errPipe.fileHandleForReading)

        var summary: IndexSummary?
        var reportedError: String?
        let decoder = JSONDecoder()

        do {
            for try await line in outPipe.fileHandleForReading.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let parsed = try? decoder.decode(IndexStreamLine.self, from: data)
                else { continue }

                if parsed.isError {
                    reportedError = parsed.message ?? "Indexing failed"
                } else if parsed.isComplete {
                    summary = parsed.asSummary()
                } else {
                    onProgress(parsed.asProgress())
                }
            }
        } catch {
            // Reading failed mid-stream; fall through and report via stderr.
        }

        let err = await stderrData
        process.waitUntilExit()

        if let reportedError {
            throw HelperError.helperReturnedError(reportedError)
        }
        if let summary {
            return summary
        }
        let errText = String(data: err, encoding: .utf8) ?? ""
        let detail = errText.isEmpty ? "no output (exit code \(process.terminationStatus))" : errText
        throw HelperError.processFailed(detail)
    }

    /// Build a helper subprocess (validating the script + interpreter) wired to
    /// fresh stdout/stderr pipes. Does not start it.
    private func makeProcess(_ args: [String]) throws -> (Process, Pipe, Pipe) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: mainScript) else {
            throw HelperError.helperNotFound(mainScript)
        }
        let python = pythonExecutable()
        guard fileManager.isExecutableFile(atPath: python) else {
            throw HelperError.pythonNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [mainScript] + args
        process.currentDirectoryURL = URL(fileURLWithPath: helperDirectory)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        return (process, outPipe, errPipe)
    }

    private func launch(_ process: Process) throws {
        do {
            try process.run()
        } catch {
            throw HelperError.processFailed(
                "could not launch \(process.executableURL?.path ?? "python"): \(error.localizedDescription)"
            )
        }
    }

    private func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.readDataToEndOfFile()
                continuation.resume(returning: data)
            }
        }
    }

    /// Prefer the project virtualenv, then a system python3.
    private func pythonExecutable() -> String {
        let fileManager = FileManager.default
        let repoRoot = (helperDirectory as NSString).deletingLastPathComponent
        let candidates = [
            (repoRoot as NSString).appendingPathComponent(".venv/bin/python3"),
            (helperDirectory as NSString).appendingPathComponent(".venv/bin/python3"),
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3",
        ]
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/python3"
    }
}
