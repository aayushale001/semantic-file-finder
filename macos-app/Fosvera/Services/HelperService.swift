import Foundation

enum HelperError: LocalizedError {
    case helperNotFound(String)
    case pythonNotFound
    case processFailed(String)
    case decodingFailed(String)
    case helperReturnedError(String)
    /// Gemini explicitly rejected the supplied API key.
    case invalidAPIKey
    /// The Gemini API rejected a call for quota / rate-limit reasons (HTTP 429).
    case quotaExceeded(String)
    /// Gemini could not be reached because the device appears offline.
    case networkUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .helperNotFound(let path):
#if DEBUG
            return "Python helper not found at \(path). Set FOSVERA_HELPER_DIR or the helperDirectory default."
#else
            return "Bundled helper not found at \(path). Reinstall Fosvera or report a release packaging issue."
#endif
        case .pythonNotFound:
            return "Could not find a Python interpreter (looked for the project .venv and /usr/bin/python3)."
        case .processFailed(let message):
            return "Helper failed: \(message)"
        case .decodingFailed(let message):
            return "Could not read helper output: \(message)"
        case .helperReturnedError(let message):
            return message
        case .invalidAPIKey:
            return "That API key was rejected by Google. Double-check it in Google AI Studio and paste it again."
        case .quotaExceeded:
            return "You've reached your Gemini API quota or rate limit. Wait a little and try again, or check your usage and billing limits in Google AI Studio."
        case .networkUnavailable:
            return "You're offline, or Gemini can't be reached. Semantic search and indexing need internet, but local filename/text search can still work."
        }
    }

    /// True when the failure was a Gemini quota / rate-limit (HTTP 429) error.
    var isQuotaExceeded: Bool {
        if case .quotaExceeded = self { return true }
        return false
    }

    /// True when Gemini was unreachable because the network appears unavailable.
    var isNetworkUnavailable: Bool {
        if case .networkUnavailable = self { return true }
        return false
    }

    /// True only when Gemini explicitly says the supplied API key is invalid.
    /// Network, quota, and transient helper failures must not be treated as a
    /// reason to discard a key the user just saved.
    var isInvalidAPIKey: Bool {
        if case .invalidAPIKey = self { return true }
        return false
    }
}

/// Talks to the Python helper.
///
/// Interactive commands (search, list, status, remove, reset, …) go through a
/// single long-lived `main.py serve` process speaking newline-delimited JSON
/// over stdin/stdout. After the first call the Python interpreter, Gemini
/// client, and LanceDB connection are all warm, so a command costs ~1 ms of
/// transport instead of the ~1.2 s a fresh interpreter took. Each request
/// carries an `id`; a background reader routes every response line back to its
/// awaiting caller, so callers just `await` as before.
///
/// Indexing intentionally still runs as its own one-shot subprocess: the server
/// loop is serial, and a long background index must never queue an interactive
/// search behind it. The two processes share the LanceDB directory safely —
/// `open_table` in the server re-reads the latest committed version, so the
/// index subprocess's writes are always visible here.
actor HelperService {
    private static let bundledHelperDirectoryName = "helper"
    private static let bundledHelperExecutableName = "fosvera-helper"
#if DEBUG
    private static let legacyDevelopmentHelperDirectory =
        "/Users/aayushale/Desktop/VectorBasedFileSearch/helper"
#endif

    /// Directory containing either:
    /// - a release helper executable named `fosvera-helper`, or
    /// - the source helper's `main.py` for development.
    ///
    /// Resolution order:
    /// 1. Debug only: `FOSVERA_HELPER_DIR` environment override.
    /// 2. Debug only: `helperDirectory` UserDefaults override.
    /// 3. A bundled release helper in `Contents/Resources/helper`.
    /// 4. Debug only: common source-tree locations for `swift run` / Xcode development.
    var helperDirectory: String {
#if DEBUG
        if let override = ProcessInfo.processInfo.environment["FOSVERA_HELPER_DIR"], !override.isEmpty {
            return override
        }
        // Compatibility with existing development setups that used the former
        // SEMANTIC_HELPER_DIR name. New docs use FOSVERA_HELPER_DIR.
        if let override = ProcessInfo.processInfo.environment["SEMANTIC_HELPER_DIR"], !override.isEmpty {
            return override
        }
        if let override = UserDefaults.standard.string(forKey: "helperDirectory"), !override.isEmpty {
            return override
        }
#endif
        if let bundled = Self.bundledHelperDirectory() {
            return bundled
        }
#if DEBUG
        return Self.developmentHelperDirectory()
#else
        return Self.bundledHelperDirectoryPath() ?? Self.bundledHelperDirectoryName
#endif
    }

    private var mainScript: String {
        (helperDirectory as NSString).appendingPathComponent("main.py")
    }

    private var bundledHelperExecutable: String {
        (helperDirectory as NSString).appendingPathComponent(Self.bundledHelperExecutableName)
    }

    /// Ceilings for a hung server, not expected durations. Local commands answer
    /// from disk; search can legitimately spend minutes in Gemini retries, so its
    /// ceiling sits above the embed layer's worst-case retry schedule.
    private static let localTimeout: TimeInterval = 30
    private static let remoteTimeout: TimeInterval = 360
    /// Above the helper's 45 s HTTP timeout, so a slow key check surfaces the
    /// real network error instead of a generic "timed out".
    private static let keyCheckTimeout: TimeInterval = 60

    // MARK: - Public API

    /// Index `path` in a dedicated subprocess, streaming NDJSON progress.
    /// Progress callbacks are delivered off the main actor.
    func indexFolder(
        path: String,
        force: Bool = false,
        prune: Bool = false,
        onProgress: (@Sendable (IndexProgress) -> Void)? = nil
    ) async throws -> IndexSummary {
        var args = ["index", path, "--progress"]
        if force { args.append("--force") }
        if prune { args.append("--prune") }

        let summary = try await runIndexStreaming(args, onProgress: onProgress)
        if summary.status != "success" {
            throw HelperError.helperReturnedError(summary.message ?? "Indexing failed")
        }
        return summary
    }

    func search(query: String, limit: Int = 10, scope: SearchScope = .auto) async throws -> SearchOutcome {
        let response = try await request(
            "search",
            args: ["query": query, "limit": limit, "scope": scope.rawValue],
            timeout: Self.remoteTimeout,
            as: SearchResponse.self
        )
        if response.status != "success" {
            throw Self.mapError(message: response.message, errorCode: response.errorCode)
        }
        return SearchOutcome(
            results: response.results ?? [],
            resolvedScope: response.resolvedScope,
            searchMode: response.searchMode,
            fallbackReason: response.fallbackReason,
            message: response.message,
            isFallback: response.isFallback ?? false
        )
    }

    func localSearch(query: String, limit: Int = 50, scope: SearchScope = .auto) async throws -> SearchOutcome {
        let response = try await request(
            "local-search",
            args: ["query": query, "limit": limit, "scope": scope.rawValue],
            timeout: Self.localTimeout,
            as: SearchResponse.self
        )
        if response.status != "success" {
            throw HelperError.helperReturnedError(response.message ?? "Local search failed")
        }
        return SearchOutcome(
            results: response.results ?? [],
            resolvedScope: response.resolvedScope,
            searchMode: response.searchMode,
            fallbackReason: response.fallbackReason,
            message: response.message,
            isFallback: response.isFallback ?? false
        )
    }

    func getStatus() async throws -> HelperStatus {
        try await runOneShot(["status"], as: HelperStatus.self)
    }

    func listFiles() async throws -> [IndexedFile] {
        let response = try await runOneShot(["list"], as: ListFilesResponse.self)
        if response.status != "success" {
            throw HelperError.helperReturnedError(response.message ?? "Listing files failed")
        }
        return response.files ?? []
    }

    func getModelInfo() async throws -> ModelInfo {
        try await runOneShot(["model-info"], as: ModelInfo.self)
    }

    /// Drop every indexed file under `path` (used when a watched folder is removed).
    @discardableResult
    func removeFolder(path: String) async throws -> Int {
        let response = try await request(
            "remove",
            args: ["folder": path],
            timeout: Self.localTimeout,
            as: RemoveResponse.self
        )
        if response.status != "success" {
            throw HelperError.helperReturnedError(response.message ?? "Removing folder failed")
        }
        return response.removedFiles ?? 0
    }

    func resetIndex() async throws {
        let response = try await request("reset", timeout: Self.localTimeout, as: HelperStatus.self)
        if response.status != "success" {
            throw HelperError.helperReturnedError(response.message ?? "Reset failed")
        }
    }

    /// Validate the configured Gemini key with a models.list metadata call.
    /// Throws with a user-readable message when the key is missing or rejected.
    func checkAPIKey() async throws {
        let response = try await request("check-key", timeout: Self.keyCheckTimeout, as: HelperStatus.self)
        if response.status != "success" {
            throw HelperError.helperReturnedError(response.message ?? "API key check failed")
        }
    }

    /// Tear down the persistent server so the next request spawns a fresh one.
    /// Used after the API key changes: the running server captured the old
    /// environment and caches its Gemini client, so it must be recycled.
    func restartServer() {
        tearDownServer(failingPendingWith: .processFailed("the helper restarted to apply new settings"))
    }

    /// Map a helper error payload to a typed `HelperError`, distinguishing the
    /// quota and offline cases so the app can react to each specifically.
    static func mapError(message: String?, errorCode: String?) -> HelperError {
        if errorCode == "quota_exceeded" {
            return .quotaExceeded(message ?? "Gemini API limit reached")
        }
        if errorCode == "network_unavailable" {
            return .networkUnavailable(message ?? "Gemini is unreachable")
        }
        if errorCode == "invalid_api_key" {
            return .invalidAPIKey
        }
        if errorCode == "no_api_key" {
            return .helperReturnedError("No Gemini API key is configured yet.")
        }
        return .helperReturnedError(message ?? "The helper reported an error.")
    }

    // MARK: - Persistent server

    /// One line of the server's stdout: `id` ties it to a request, `type` is
    /// "result", "error", or "progress" (the startup "ready" line has no id).
    private struct ServerEnvelope: Decodable {
        let id: String?
        let type: String?
        let message: String?
        let errorCode: String?

        enum CodingKeys: String, CodingKey {
            case id, type, message
            case errorCode = "error_code"
        }
    }

    /// One-shot CLI error payload: `{"status":"error","message":...}`.
    private struct ProcessErrorEnvelope: Decodable {
        let status: String?
        let message: String?
        let errorCode: String?

        enum CodingKeys: String, CodingKey {
            case status, message
            case errorCode = "error_code"
        }
    }

    private var server: Process?
    private var serverStdin: FileHandle?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var stderrTail: [String] = []
    private var requestCounter = 0

    /// Send one command to the server and decode its terminal reply.
    private func request<T: Decodable>(
        _ cmd: String,
        args: [String: Any] = [:],
        timeout: TimeInterval,
        as type: T.Type
    ) async throws -> T {
        let data = try await sendRequest(cmd, args: args, timeout: timeout)
        do {
            // The envelope's extra keys (id/type) are ignored by Codable.
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let text = String(data: data, encoding: .utf8) ?? "<non-utf8 output>"
            throw HelperError.decodingFailed("\(error.localizedDescription)\nOutput: \(text)")
        }
    }

    private func sendRequest(_ cmd: String, args: [String: Any], timeout: TimeInterval) async throws -> Data {
        try ensureServerRunning()
        guard let stdin = serverStdin else {
            throw HelperError.processFailed("helper server is not running")
        }
        requestCounter += 1
        let id = "\(requestCounter)"
        var object: [String: Any] = ["id": id, "cmd": cmd]
        if !args.isEmpty { object["args"] = args }
        var line = try JSONSerialization.data(withJSONObject: object)
        line.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try stdin.write(contentsOf: line)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: HelperError.processFailed(
                    "could not send \(cmd) to the helper: \(error.localizedDescription)"))
                return
            }
            timeoutTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.timeOutRequest(id: id, cmd: cmd, seconds: timeout)
            }
        }
    }

    /// Spawn the helper server if it isn't already running, and start draining
    /// its pipes. In release builds this prefers the frozen helper executable;
    /// in development it falls back to `python main.py serve`. Requests written
    /// before the helper finishes importing simply wait in the pipe buffer, so
    /// there is no startup race.
    private func ensureServerRunning() throws {
        if let server, server.isRunning { return }
        tearDownServer(failingPendingWith: .processFailed("the helper restarted"))

        let fileManager = FileManager.default

        let process = Process()
        if fileManager.isExecutableFile(atPath: bundledHelperExecutable) {
            process.executableURL = URL(fileURLWithPath: bundledHelperExecutable)
            process.arguments = ["serve"]
        } else {
            guard fileManager.fileExists(atPath: mainScript) else {
                throw HelperError.helperNotFound(
                    "\(mainScript) or \(bundledHelperExecutable)"
                )
            }
            let python = pythonExecutable()
            guard fileManager.isExecutableFile(atPath: python) else {
                throw HelperError.pythonNotFound
            }
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [mainScript, "serve"]
        }
        process.currentDirectoryURL = URL(fileURLWithPath: helperDirectory)
        process.environment = helperEnvironment()
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw HelperError.processFailed(
                "could not launch \(process.executableURL?.path ?? "helper"): \(error.localizedDescription)")
        }

        server = process
        serverStdin = inPipe.fileHandleForWriting
        stderrTail = []

        // Route each stdout line to its waiting request. EOF means the server
        // exited (crash, or our own shutdown) — fail whatever is still in flight;
        // the next request will respawn it. When the app itself dies, the closed
        // stdin pipe makes the server exit, so no explicit shutdown is needed.
        Task { [weak self] in
            do {
                for try await line in outPipe.fileHandleForReading.bytes.lines {
                    await self?.handleServerLine(line)
                }
            } catch {}
            await self?.serverDidExit(process)
        }
        // Keep a short stderr tail for crash diagnostics (full logs go to the
        // helper's log file).
        Task { [weak self] in
            do {
                for try await line in errPipe.fileHandleForReading.bytes.lines {
                    await self?.recordStderr(line)
                }
            } catch {}
        }
    }

    private func handleServerLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ServerEnvelope.self, from: data),
              let id = envelope.id
        else { return }   // e.g. the startup "ready" line

        switch envelope.type {
        case "progress":
            break         // indexing doesn't run through the server (yet)
        case "error":
            resolve(id: id, with: .failure(Self.mapError(message: envelope.message, errorCode: envelope.errorCode)))
        default:
            resolve(id: id, with: .success(data))
        }
    }

    private func resolve(id: String, with result: Result<Data, Error>) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard let continuation = pending.removeValue(forKey: id) else { return }
        switch result {
        case .success(let data): continuation.resume(returning: data)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    private func timeOutRequest(id: String, cmd: String, seconds: TimeInterval) {
        timeoutTasks[id] = nil
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: HelperError.processFailed(
            "\(cmd) timed out after \(Int(seconds))s"))
        // A server that stopped answering can't be trusted with the next request
        // either — recycle it. The reader's EOF fails any other in-flight calls,
        // and the next request spawns a fresh one.
        if let server, server.isRunning { server.terminate() }
    }

    private func serverDidExit(_ process: Process) {
        guard process === server else { return }   // stale notification from an old server
        var detail = "the helper stopped unexpectedly"
        if !process.isRunning {
            detail += " (exit code \(process.terminationStatus))"
        }
        let tail = stderrTail.suffix(4).joined(separator: "\n")
        if !tail.isEmpty { detail += ":\n\(tail)" }
        tearDownServer(failingPendingWith: .processFailed(detail))
    }

    private func tearDownServer(failingPendingWith error: HelperError) {
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
        try? serverStdin?.close()
        serverStdin = nil
        if let server, server.isRunning { server.terminate() }
        server = nil
    }

    private func recordStderr(_ line: String) {
        stderrTail.append(line)
        if stderrTail.count > 20 { stderrTail.removeFirst(stderrTail.count - 20) }
    }

    // MARK: - One-shot local subprocesses

    /// Run a short helper CLI command in its own process. Startup/home commands
    /// use this path so the indexed-files gallery is never blocked by a stale
    /// persistent server.
    ///
    /// These commands answer from local disk, so `timeout` is a hang ceiling,
    /// not an expected duration: a helper that blows past it is terminated so
    /// the UI never waits forever on a wedged process.
    private func runOneShot<T: Decodable>(
        _ args: [String],
        timeout: TimeInterval = HelperService.localTimeout,
        as type: T.Type
    ) async throws -> T {
        let (process, outPipe, errPipe) = try makeProcess(args)
        try launch(process)

        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, process.isRunning else { return false }
            process.terminate()
            // Give SIGTERM a moment; force-kill if the helper ignores it.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return true
        }

        async let stdoutData = readToEnd(outPipe.fileHandleForReading)
        async let stderrData = readToEnd(errPipe.fileHandleForReading)
        let out = await stdoutData
        let err = await stderrData
        process.waitUntilExit()
        watchdog.cancel()
        if await watchdog.value {
            throw HelperError.processFailed(
                "\(args.first ?? "helper") timed out after \(Int(timeout))s")
        }

        if out.isEmpty {
            let errText = String(data: err, encoding: .utf8) ?? ""
            let detail = errText.isEmpty ? "no output (exit code \(process.terminationStatus))" : errText
            throw HelperError.processFailed(detail)
        }

        if let env = try? JSONDecoder().decode(ProcessErrorEnvelope.self, from: out),
           env.status == "error" {
            throw Self.mapError(message: env.message, errorCode: env.errorCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: out)
        } catch {
            let text = String(data: out, encoding: .utf8) ?? "<non-utf8 output>"
            throw HelperError.decodingFailed("\(error.localizedDescription)\nOutput: \(text)")
        }
    }

    // MARK: - One-shot index subprocess

    /// Runs `index --progress` in its own process and reads stdout as NDJSON.
    /// `start`/`progress` lines are forwarded to `onProgress`; the terminal
    /// `complete` line is returned as the summary. stderr is drained concurrently
    /// so a chatty log stream can never deadlock the pipe.
    private func runIndexStreaming(
        _ args: [String],
        onProgress: (@Sendable (IndexProgress) -> Void)?
    ) async throws -> IndexSummary {
        let (process, outPipe, errPipe) = try makeProcess(args)
        try launch(process)

        async let stderrData = readToEnd(errPipe.fileHandleForReading)

        var summary: IndexSummary?
        var reportedError: HelperError?
        let decoder = JSONDecoder()

        do {
            for try await line in outPipe.fileHandleForReading.bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let parsed = try? decoder.decode(IndexStreamLine.self, from: data)
                else { continue }

                if parsed.isError {
                    reportedError = Self.mapError(message: parsed.message, errorCode: parsed.errorCode)
                } else if parsed.isComplete {
                    summary = parsed.asSummary()
                } else {
                    onProgress?(parsed.asProgress())
                }
            }
        } catch {
            // Reading failed mid-stream; fall through and report via stderr.
        }

        let err = await stderrData
        process.waitUntilExit()

        if let reportedError {
            throw reportedError
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

        let process = Process()
        if fileManager.isExecutableFile(atPath: bundledHelperExecutable) {
            process.executableURL = URL(fileURLWithPath: bundledHelperExecutable)
            process.arguments = args
        } else {
            guard fileManager.fileExists(atPath: mainScript) else {
                throw HelperError.helperNotFound(
                    "\(mainScript) or \(bundledHelperExecutable)"
                )
            }
            let python = pythonExecutable()
            guard fileManager.isExecutableFile(atPath: python) else {
                throw HelperError.pythonNotFound
            }
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [mainScript] + args
        }
        process.currentDirectoryURL = URL(fileURLWithPath: helperDirectory)
        process.environment = helperEnvironment()

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
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

    /// Environment for helper processes.
    ///
    /// Product rule: the macOS app uses the user's Keychain-saved API key, not a
    /// developer `.env` or inherited shell `GEMINI_API_KEY`. This keeps first-run
    /// behavior honest for release builds: if the user has not pasted a key into
    /// Settings, the app should say no key is configured.
    ///
    /// Developers can temporarily opt back into environment/.env keys by setting
    /// `SFF_ALLOW_APP_ENV_API_KEY=1` before launching the app.
    private func helperEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let allowDeveloperEnvKey = Self.allowsDevelopmentHelperOverrides
            && Self.envBool(environment["SFF_ALLOW_APP_ENV_API_KEY"])
        environment["SFF_LOAD_DOTENV"] = allowDeveloperEnvKey ? "1" : "0"

        if let key = KeychainStore.readAPIKey(allowPrompt: false) {
            environment["GEMINI_API_KEY"] = key
        } else if !allowDeveloperEnvKey {
            environment.removeValue(forKey: "GEMINI_API_KEY")
        }
        return environment
    }

    private static var allowsDevelopmentHelperOverrides: Bool {
#if DEBUG
        return true
#else
        return false
#endif
    }

    private static func envBool(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return ["1", "true", "yes", "on"].contains(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Prefer a bundled/repo virtualenv, then a system python3.
    private func pythonExecutable() -> String {
        let fileManager = FileManager.default
        let repoRoot = (helperDirectory as NSString).deletingLastPathComponent
        let resourcePython = Bundle.main.resourceURL?
            .appendingPathComponent("python/bin/python3")
            .path
        let candidates = [
            (repoRoot as NSString).appendingPathComponent(".venv/bin/python3"),
            (helperDirectory as NSString).appendingPathComponent(".venv/bin/python3"),
            resourcePython,
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3",
        ].compactMap { $0 }
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/python3"
    }

    private static func bundledHelperDirectoryPath() -> String? {
        Bundle.main.resourceURL?.appendingPathComponent(bundledHelperDirectoryName).path
    }

    private static func bundledHelperDirectory() -> String? {
        guard let directory = bundledHelperDirectoryPath() else { return nil }
        let executable = (directory as NSString).appendingPathComponent(bundledHelperExecutableName)
        let bundledPython = Bundle.main.resourceURL?
            .appendingPathComponent("python/bin/python3")
            .path
        let helperVenvPython = (directory as NSString).appendingPathComponent(".venv/bin/python3")
        let main = (directory as NSString).appendingPathComponent("main.py")

        let fileManager = FileManager.default
        if fileManager.isExecutableFile(atPath: executable) {
            return directory
        }
        if fileManager.fileExists(atPath: main),
           fileManager.isExecutableFile(atPath: bundledPython ?? "") || fileManager.isExecutableFile(atPath: helperVenvPython) {
            return directory
        }
        return nil
    }

#if DEBUG
    private static func developmentHelperDirectory() -> String {
        let fileManager = FileManager.default
        let cwd = fileManager.currentDirectoryPath
        let candidates = [
            (cwd as NSString).appendingPathComponent("helper"),
            (cwd as NSString).appendingPathComponent("../helper"),
            (cwd as NSString).appendingPathComponent("../../helper"),
            legacyDevelopmentHelperDirectory,
        ]

        for candidate in candidates {
            let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            let main = (standardized as NSString).appendingPathComponent("main.py")
            if fileManager.fileExists(atPath: main) {
                return standardized
            }
        }

        return legacyDevelopmentHelperDirectory
    }
#endif
}
