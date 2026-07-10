import Foundation
import CoreServices

/// Watches a set of folders with FSEvents and reports — debounced — which watched
/// roots changed, so the app can incrementally re-index just those folders.
///
/// Owned by the `@MainActor` view model; `onChange` is always delivered on the
/// main queue. The FSEvents C callback runs on a private dispatch queue and
/// forwards raw paths through `handle(paths:)`, which maps them back to the
/// watched roots and coalesces a burst of edits into one event per root.
final class FolderWatcher {
    /// Delivered on the main queue with the set of watched roots that changed.
    var onChange: ((Set<String>) -> Void)?

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.fosvera.folderwatcher")
    /// Guards `roots`, `pending`, and `flushWork` — all are touched both by the
    /// main thread (start/stop) and by the FSEvents callback on `queue`.
    private let lock = NSLock()
    private var roots: [String] = []
    private var pending = Set<String>()
    private var flushWork: DispatchWorkItem?

    /// Coalesce a burst of saves into a single re-index per root.
    private let debounce: TimeInterval = 2.0

    deinit { stop() }

    /// Begin watching exactly `paths`, replacing any current watch.
    func start(paths: [String]) {
        stop()
        let normalized = paths.map {
            URL(fileURLWithPath: $0)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
        lock.lock()
        roots = normalized
        lock.unlock()
        guard !normalized.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagUseCFTypes
        )
        // Captures nothing, so it converts to the C function pointer FSEvents needs;
        // `self` is recovered from the context's info pointer instead.
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = unsafeBitCast(eventPaths, to: CFArray.self)
            var changed: [String] = []
            changed.reserveCapacity(count)
            for i in 0..<count {
                let raw = CFArrayGetValueAtIndex(cfPaths, i)
                let path = unsafeBitCast(raw, to: CFString.self) as String
                changed.append(path)
            }
            watcher.handle(paths: changed)
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            normalized as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,                       // FSEvents native coalescing latency (seconds)
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        lock.lock()
        pending.removeAll()
        flushWork?.cancel()
        flushWork = nil
        lock.unlock()
    }

    /// Map changed paths to the watched roots that contain them, then debounce.
    private func handle(paths: [String]) {
        lock.lock()
        for path in paths {
            if let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                pending.insert(root)
            }
        }
        lock.unlock()
        scheduleFlush()
    }

    private func scheduleFlush() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let changedRoots = self.pending
            self.pending.removeAll()
            self.lock.unlock()
            guard !changedRoots.isEmpty else { return }
            DispatchQueue.main.async { self.onChange?(changedRoots) }
        }
        lock.lock()
        flushWork?.cancel()
        flushWork = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
