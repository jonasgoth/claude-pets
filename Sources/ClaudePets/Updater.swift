import AppKit

/// Keeps Claude Pets current from its GitHub releases.
///
/// Every release is a `claude-pets-<version>.dmg` attached to a `v<version>` tag, published by
/// .github/workflows/release.yml. This asks GitHub's API which release is newest, and when
/// you click the menu row it downloads that DMG, swaps this copy of the app for the one
/// inside, and relaunches.
///
/// Two details worth knowing:
///
/// - The download goes through URLSession, not a browser, so macOS never marks the file
///   as quarantined. That matters because Claude Pets is ad-hoc signed, not notarized: a
///   quarantined copy would be refused outright instead of merely warned about.
/// - An app cannot delete itself while it is running, so the swap is handed to a small
///   shell script that waits for us to quit first.
final class Updater {
    static let repo = "jonasgoth/claude-pets"

    struct Release {
        let version: String
        let tag: String
        let dmg: URL
    }

    /// The newest release, once we know it is newer than what is running. nil the rest of the time.
    private(set) var available: Release?
    /// True while a download or swap is in flight, so the menu row can say so.
    private(set) var isInstalling = false
    /// Called whenever either of the above changes, so the menu can redraw.
    var onChange: (() -> Void)?

    private var timer: Timer?
    private let session = URLSession(configuration: .ephemeral)

    /// Checks shortly after launch, then a few times a day. Six hours is often enough to
    /// notice a release the same day and rare enough that nobody notices the traffic.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check() }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Looking for a new version

    func check() {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")
        else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudePets/\(AppDelegate.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        session.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data, let release = Self.parse(data) else { return }
            guard Self.isNewer(release.version, than: AppDelegate.version) else { return }
            DispatchQueue.main.async {
                guard self.available?.version != release.version else { return }
                self.available = release
                self.onChange?()
            }
        }.resume()
    }

    /// Pulls the tag and the DMG's download link out of GitHub's JSON.
    private static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              json["draft"] as? Bool != true,
              let assets = json["assets"] as? [[String: Any]] else { return nil }

        let link = assets.compactMap { $0["browser_download_url"] as? String }
            .first { $0.hasSuffix(".dmg") }
        // Only ever fetch from GitHub itself, whatever the API happens to say.
        guard let link, let url = URL(string: link), let host = url.host,
              url.scheme == "https",
              host == "github.com" || host.hasSuffix(".github.com")
                  || host.hasSuffix(".githubusercontent.com") else { return nil }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, tag: tag, dmg: url)
    }

    /// Plain numeric comparison of dotted versions: 0.10.0 beats 0.9.0, and a shorter
    /// version is padded with zeroes so 0.6 and 0.6.0 count as the same.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let left = i < a.count ? a[i] : 0
            let right = i < b.count ? b[i] : 0
            if left != right { return left > right }
        }
        return false
    }

    // MARK: - Installing it

    /// Downloads the release and swaps this app for it. `done` reports a problem, and is
    /// never called on success: by then the new copy is launching and this one is quitting.
    func install(_ release: Release, done: @escaping (String?) -> Void) {
        let destination = Bundle.main.bundleURL
        guard destination.pathExtension == "app" else {
            return done("Claude Pets is running from a build folder, not an app bundle. "
                        + "Updating only works on an installed copy.")
        }
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path)
        else {
            return done("Claude Pets cannot write to \(destination.deletingLastPathComponent().path). "
                        + "Move Claude Pets to your Applications folder and try again.")
        }

        isInstalling = true
        onChange?()

        session.downloadTask(with: release.dmg) { [weak self] temp, response, error in
            guard let self else { return }
            let fail: (String) -> Void = { message in
                DispatchQueue.main.async {
                    self.isInstalling = false
                    self.onChange?()
                    done(message)
                }
            }
            if let error { return fail("The download failed: \(error.localizedDescription)") }
            guard let temp,
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false
            else { return fail("The download failed.") }

            // URLSession deletes its temp file the moment this closure returns, so move it first.
            let work = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("claude-pets-update-\(UUID().uuidString)")
            let dmg = work.appendingPathComponent("claude-pets.dmg")
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: temp, to: dmg)
            } catch {
                return fail("Could not unpack the download: \(error.localizedDescription)")
            }

            switch Self.stageApp(from: dmg, into: work) {
            case .failure(let problem):
                try? FileManager.default.removeItem(at: work)
                fail(problem.message)
            case .success(let staged):
                DispatchQueue.main.async {
                    Self.swapAndRelaunch(staged: staged, destination: destination, work: work)
                }
            }
        }.resume()
    }

    /// A problem worth showing the person who clicked Update.
    private struct Problem: Error { let message: String }

    /// Mounts the disk image, copies Claude Pets.app off it, unmounts. Returns the copy.
    private static func stageApp(from dmg: URL, into work: URL) -> Result<URL, Problem> {
        let mount = work.appendingPathComponent("mnt")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)

        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-mountpoint", mount.path,
                                       "-nobrowse", "-readonly", "-noautoopen", "-quiet"])
        else { return .failure(Problem(message: "Could not open the downloaded disk image.")) }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"]) }

        let source = mount.appendingPathComponent("Claude Pets.app")
        let staged = work.appendingPathComponent("Claude Pets.app")
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("Contents/MacOS/ClaudePets").path)
        else { return .failure(Problem(message: "The downloaded disk image does not contain Claude Pets.")) }
        // ditto, not copyItem: it keeps the code signature and the bundle's symlinks intact.
        guard run("/usr/bin/ditto", [source.path, staged.path])
        else { return .failure(Problem(message: "Could not copy the new version off the disk image.")) }
        return .success(staged)
    }

    /// Hands the swap to a detached shell script and quits, since the bundle being replaced
    /// is the one this process is running from.
    private static func swapAndRelaunch(staged: URL, destination: URL, work: URL) {
        let script = work.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/sh
        # Written by the Claude Pets updater. Waits for the old copy to quit, puts the new one in
        # its place, relaunches it, then deletes itself.
        new=\(shellQuoted(staged.path))
        dest=\(shellQuoted(destination.path))
        work=\(shellQuoted(work.path))

        i=0
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null && [ $i -lt 150 ]; do
          sleep 0.2
          i=$((i + 1))
        done

        rm -rf "$dest.old"
        mv "$dest" "$dest.old" 2>/dev/null
        if ditto "$new" "$dest"; then
          rm -rf "$dest.old"
        else
          # Put the old one back rather than leave the Mac with no Claude Pets at all.
          rm -rf "$dest"
          mv "$dest.old" "$dest"
        fi
        xattr -cr "$dest" 2>/dev/null
        open "$dest"
        # This script lives in $work, so clean up from a separate process once it has exited.
        (sleep 5; rm -rf "$work") &
        """
        guard (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [script.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Small helpers

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// Wraps a path in single quotes for /bin/sh, so spaces in it cannot split an argument.
    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
