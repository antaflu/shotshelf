import Foundation

/// Watches the staging folder and reports each new screenshot once the file
/// has been written completely.
final class ScreenshotWatcher {
    private let directory: URL
    private let queue = DispatchQueue(label: "nl.shotshelf.watcher")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var timer: DispatchSourceTimer?
    private var seen = Set<String>()
    private var pending = Set<String>()

    /// Called on the main queue for every new, complete file.
    var onNewScreenshot: ((URL) -> Void)?

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "pdf"]

    init(directory: URL) {
        self.directory = directory
    }

    deinit { stop() }

    /// Adopts files already in the staging folder (after a crash, say) without
    /// reporting them as new; the caller puts them straight on the shelf.
    func existingFiles() -> [URL] {
        let files = currentFiles()
        seen.formUnion(files.map(\.lastPathComponent))
        return files.sorted { lhs, rhs in
            (modificationDate(lhs) ?? .distantPast) < (modificationDate(rhs) ?? .distantPast)
        }
    }

    func start() {
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            NSLog("ShotShelf: cannot open the staging folder, falling back to polling")
            startPolling()
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .rename], queue: queue)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }
        src.resume()
        source = src
        startPolling() // safety net: directory events occasionally miss a write
    }

    func stop() {
        source?.cancel()
        source = nil
        timer?.cancel()
        timer = nil
    }

    // MARK: - Intern

    private func startPolling() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    private func currentFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents.filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func scan() {
        for url in currentFiles() {
            let name = url.lastPathComponent
            guard !seen.contains(name), !pending.contains(name) else { continue }
            pending.insert(name)
            waitUntilStable(url)
        }
    }

    /// screencapture writes the file in chunks; wait until the size stays the
    /// same for two checks before picking the screenshot up.
    private func waitUntilStable(_ url: URL, attempt: Int = 0, lastSize: Int = -1) {
        queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            let name = url.lastPathComponent
            guard FileManager.default.fileExists(atPath: url.path) else {
                self.pending.remove(name)
                return
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size > 0 && size == lastSize {
                self.pending.remove(name)
                self.seen.insert(name)
                DispatchQueue.main.async { self.onNewScreenshot?(url) }
                return
            }
            guard attempt < 60 else { // ~7 s, then give up
                self.pending.remove(name)
                return
            }
            self.waitUntilStable(url, attempt: attempt + 1, lastSize: size)
        }
    }

    /// Forgets a file name so a later screenshot with the same name is picked
    /// up again.
    func forget(_ url: URL) {
        queue.async { self.seen.remove(url.lastPathComponent) }
    }
}
