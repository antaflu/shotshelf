import AppKit
import Combine
import CryptoKit

/// Looks for new versions on GitHub Releases, downloads them in the background
/// and installs them on the next relaunch.
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release {
        let version: String
        let notes: String
        let page: URL
        let dmg: URL
        let checksum: URL?
    }

    enum State: Equatable {
        case idle
        case notConfigured
        case checking
        case upToDate(checkedAt: Date)
        case available(version: String)
        case downloading(version: String, progress: Double)
        case ready(version: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var latest: Release?

    /// "owner/repo" from Info.plist, set by build.sh.
    let repository: String? = {
        guard let repo = Bundle.main.object(forInfoDictionaryKey: "ShotShelfUpdateRepo") as? String,
              repo.contains("/") else { return nil }
        return repo
    }()

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private var preparedApp: URL?
    private var timer: Timer?
    private var progressObservation: NSKeyValueObservation?
    private let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("ShotShelfUpdate", isDirectory: true)

    private init() {
        if repository == nil { state = .notConfigured }
    }

    var repositoryPage: URL? {
        repository.flatMap { URL(string: "https://github.com/\($0)/releases") }
    }

    // MARK: - Automatic checks

    func startAutomaticChecks() {
        timer?.invalidate()
        guard repository != nil, AppSettings.shared.autoCheckUpdates else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check(automatic: true) }
        let timer = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in self?.check(automatic: true) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Checking

    func check(automatic: Bool = false) {
        guard let repository else { state = .notConfigured; return }
        switch state {
        case .checking, .downloading, .ready: return
        default: break
        }
        state = .checking

        // SHOTSHELF_UPDATE_API only exists to test the updater locally.
        let endpoint = ProcessInfo.processInfo.environment["SHOTSHELF_UPDATE_API"]
            ?? "https://api.github.com/repos/\(repository)/releases/latest"
        guard let endpointURL = URL(string: endpoint) else { state = .failed("Invalid update source."); return }
        var request = URLRequest(url: endpointURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ShotShelf/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.state = .failed("No connection: \(error.localizedDescription)")
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data else {
                    self.state = .failed(status == 404
                        ? "No releases found on GitHub yet."
                        : "GitHub returned an error (\(status)).")
                    return
                }
                guard let release = Self.parse(data) else {
                    self.state = .failed("The latest release has no DMG.")
                    return
                }
                self.latest = release
                if Self.isVersion(release.version, newerThan: self.currentVersion) {
                    self.state = .available(version: release.version)
                    if automatic { self.download() }
                } else {
                    self.state = .upToDate(checkedAt: Date())
                }
            }
        }.resume()
    }

    private static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]] else { return nil }

        func asset(_ suffix: String) -> URL? {
            assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(suffix) == true }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        guard let dmg = asset(".dmg") else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: json["body"] as? String ?? "", page: page,
                       dmg: dmg, checksum: asset(".dmg.sha256"))
    }

    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Downloading and staging

    func download() {
        guard let release = latest else { return }
        state = .downloading(version: release.version, progress: 0)
        try? FileManager.default.removeItem(at: workDir)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let task = URLSession.shared.downloadTask(with: release.dmg) { [weak self] location, _, error in
            guard let self else { return }
            // The temporary file is deleted after this closure, so move it right away.
            var dmg: URL?
            if let location {
                let target = self.workDir.appendingPathComponent("ShotShelf.dmg")
                try? FileManager.default.removeItem(at: target)
                if (try? FileManager.default.moveItem(at: location, to: target)) != nil { dmg = target }
            }
            DispatchQueue.global(qos: .utility).async {
                let result: Result<URL, UpdateError>
                if let dmg {
                    result = self.prepare(dmg: dmg, release: release)
                } else {
                    result = .failure(.message("Download failed: \(error?.localizedDescription ?? "unknown error")"))
                }
                DispatchQueue.main.async {
                    self.progressObservation = nil
                    switch result {
                    case .success(let app):
                        self.preparedApp = app
                        self.state = .ready(version: release.version)
                    case .failure(let failure):
                        self.state = .failed(failure.text)
                    }
                }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                guard let self, case .downloading(let version, _) = self.state else { return }
                self.state = .downloading(version: version, progress: progress.fractionCompleted)
            }
        }
        task.resume()
    }

    private enum UpdateError: Error {
        case message(String)
        var text: String { if case .message(let m) = self { return m }; return "" }
    }

    /// Verifies the download, mounts the DMG and copies the new app to a work folder.
    private func prepare(dmg: URL, release: Release) -> Result<URL, UpdateError> {
        if let checksumURL = release.checksum {
            guard let expectedText = try? String(contentsOf: checksumURL, encoding: .utf8),
                  let expected = expectedText.split(whereSeparator: { $0 == " " || $0 == "\n" }).first,
                  let data = try? Data(contentsOf: dmg) else {
                return .failure(.message("Could not fetch the checksum."))
            }
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else {
                return .failure(.message("The download is corrupted (checksum mismatch)."))
            }
        }

        let mountPoint = workDir.appendingPathComponent("mount", isDirectory: true)
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                       "-mountpoint", mountPoint.path]) else {
            return .failure(.message("Could not open the update."))
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

        let mountedApp = mountPoint.appendingPathComponent("ShotShelf.app")
        guard let bundle = Bundle(url: mountedApp),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            return .failure(.message("The update does not contain a valid ShotShelf app."))
        }
        let newVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard Self.isVersion(newVersion, newerThan: currentVersion) else {
            return .failure(.message("The downloaded version (\(newVersion)) is not newer."))
        }

        let staged = workDir.appendingPathComponent("ShotShelf.app")
        try? FileManager.default.removeItem(at: staged)
        guard run("/usr/bin/ditto", [mountedApp.path, staged.path]) else {
            return .failure(.message("Could not prepare the new version."))
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return .success(staged)
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Installing

    var canWriteToAppLocation: Bool {
        FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
    }

    /// Installs now and relaunches ShotShelf.
    func installAndRelaunch() {
        guard scheduleSwap(relaunch: true) else { return }
        NSApp.terminate(nil)
    }

    /// Called on quit: an update that is ready gets installed then, so it is in
    /// place at the next launch.
    func installOnQuitIfReady() {
        _ = scheduleSwap(relaunch: false)
    }

    /// A small script waits for this app to exit, then swaps the bundle.
    private func scheduleSwap(relaunch: Bool) -> Bool {
        guard let staged = preparedApp, FileManager.default.fileExists(atPath: staged.path) else { return false }
        guard canWriteToAppLocation else {
            state = .failed("No write access to \(Bundle.main.bundleURL.deletingLastPathComponent().path).")
            return false
        }
        preparedApp = nil

        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old"
        mv "$2" "$2.old" || exit 1
        if mv "$3" "$2"; then rm -rf "$2.old"; else mv "$2.old" "$2"; fi
        if [ "$4" = "1" ]; then open "$2"; fi
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "shotshelf-update",
                             String(ProcessInfo.processInfo.processIdentifier),
                             Bundle.main.bundleURL.path, staged.path, relaunch ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            state = .failed("Could not start the installation.")
            return false
        }
    }
}
