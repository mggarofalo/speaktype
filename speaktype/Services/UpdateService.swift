import AppKit
import Combine
import Foundation

/// Service to check for app updates and manage update preferences
class UpdateService: ObservableObject {
    static let shared = UpdateService()

    @Published var availableUpdate: AppVersion?
    @Published var isCheckingForUpdates = false
    @Published var lastCheckDate: Date?

    // Install progress state
    @Published var isInstalling = false
    @Published var installProgress: Double = 0  // 0.0 – 1.0
    @Published var installStatus: String = ""  // human-readable status
    @Published var installError: String?

    // Publisher to request UI display (e.g. show update window)
    let showUpdateWindowPublisher = PassthroughSubject<AppVersion, Never>()

    // User Defaults keys
    private let lastCheckDateKey = "lastUpdateCheckDate"
    private let skippedVersionKey = "skippedVersion"
    private let autoUpdateKey = "autoUpdate"
    private let lastReminderDateKey = "lastUpdateReminderDate"

    private init() {
        loadLastCheckDate()
    }

    // MARK: - Update Checking

    /// Check for updates from server
    func checkForUpdates(silent: Bool = false) async {
        guard !isCheckingForUpdates else { return }

        await MainActor.run { isCheckingForUpdates = true }

        do {
            let url = URL(
                string: "https://api.github.com/repos/karansinghgit/speaktype/releases/latest")!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let releaseVersion = AppVersion(from: release)
            let currentVersion = AppVersion.currentVersion

            await MainActor.run {
                if AppVersion.isNewerVersion(releaseVersion.version, than: currentVersion) {
                    if !silent || !self.isVersionSkipped(releaseVersion.version) {
                        self.availableUpdate = releaseVersion
                        self.showUpdateWindowPublisher.send(releaseVersion)
                    }
                } else {
                    self.availableUpdate = nil
                }
                self.isCheckingForUpdates = false
                self.lastCheckDate = Date()
                self.saveLastCheckDate()
            }
        } catch {
            print("Failed to check for updates: \(error)")
            await MainActor.run { self.isCheckingForUpdates = false }
        }
    }

    /// Check if enough time has passed since last check (24 hours)
    func shouldCheckForUpdates() -> Bool {
        guard let lastCheck = lastCheckDate else { return true }
        return Date().timeIntervalSince(lastCheck) / 3600 >= 24
    }

    /// Check if we should show the reminder (every 24 hours)
    func shouldShowReminder() -> Bool {
        guard availableUpdate != nil else { return false }
        let lastReminder = UserDefaults.standard.object(forKey: lastReminderDateKey) as? Date
        guard let lastReminder else { return true }
        return Date().timeIntervalSince(lastReminder) / 3600 >= 24
    }

    // MARK: - Version Management

    func skipVersion(_ version: String) {
        UserDefaults.standard.set(version, forKey: skippedVersionKey)
        availableUpdate = nil
    }

    private func isVersionSkipped(_ version: String) -> Bool {
        UserDefaults.standard.string(forKey: skippedVersionKey) == version
    }

    func markReminderShown() {
        UserDefaults.standard.set(Date(), forKey: lastReminderDateKey)
    }

    func clearSkippedVersion() {
        UserDefaults.standard.removeObject(forKey: skippedVersionKey)
    }

    // MARK: - Persistence

    private func saveLastCheckDate() {
        if let date = lastCheckDate {
            UserDefaults.standard.set(date, forKey: lastCheckDateKey)
        }
    }

    private func loadLastCheckDate() {
        lastCheckDate = UserDefaults.standard.object(forKey: lastCheckDateKey) as? Date
    }

    // MARK: - Auto Update

    var isAutoUpdateEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoUpdateKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoUpdateKey) }
    }

    // MARK: - Update Installation

    /// Download the DMG, mount it, copy the .app over the running installation, and relaunch.
    func installUpdate(url downloadURLString: String) {
        guard let downloadURL = URL(string: downloadURLString) else {
            setError("Invalid download URL.")
            return
        }

        // If the URL isn't a direct asset (falls back to HTML page), open browser instead.
        guard downloadURL.pathExtension == "dmg" else {
            NSWorkspace.shared.open(downloadURL)
            return
        }

        Task {
            await MainActor.run {
                self.isInstalling = true
                self.installProgress = 0
                self.installStatus = "Downloading update…"
                self.installError = nil
            }

            do {
                // 1. Download DMG with progress
                let dmgURL = try await downloadWithProgress(from: downloadURL)

                // 2. Mount the DMG
                await MainActor.run { self.installStatus = "Mounting update…" }
                let mountPoint = try mountDMG(at: dmgURL)

                // 3. Find the .app inside the mounted volume
                await MainActor.run { self.installStatus = "Installing…" }
                let appInDMG = try findApp(in: mountPoint)

                // 4. Replace the running app
                try replaceCurrentApp(with: appInDMG)

                // 5. Detach the volume (best-effort)
                detachDMG(mountPoint: mountPoint)

                // 6. Relaunch
                await MainActor.run { self.installStatus = "Relaunching…" }
                relaunch()

            } catch {
                await MainActor.run {
                    self.isInstalling = false
                    self.installError = error.localizedDescription
                    self.installStatus = ""
                }
            }
        }
    }

    // MARK: - Private Helpers

    private func downloadWithProgress(from url: URL) async throws -> URL {
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)

        let total = response.expectedContentLength  // may be -1 if unknown
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakType-update-\(UUID().uuidString).dmg")

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }

        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1024 * 256)

        for try await byte in asyncBytes {
            buffer.append(byte)
            received += 1

            // Flush every 256 KB
            if buffer.count >= 1024 * 256 {
                handle.write(buffer)
                buffer.removeAll(keepingCapacity: true)

                if total > 0 {
                    let progress = Double(received) / Double(total)
                    await MainActor.run {
                        self.installProgress = progress * 0.8  // download = 0-80%
                        self.installStatus = "Downloading… \(Int(progress * 100))%"
                    }
                }
            }
        }

        // Flush remaining bytes
        if !buffer.isEmpty { handle.write(buffer) }

        await MainActor.run {
            self.installProgress = 0.85
            self.installStatus = "Download complete."
        }

        return dest
    }

    private func mountDMG(at dmgURL: URL) throws -> URL {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["attach", dmgURL.path, "-nobrowse", "-readonly", "-plist"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            throw UpdateError.mountFailed
        }

        let plistData = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
            let dict = plist as? [String: Any],
            let entities = dict["system-entities"] as? [[String: Any]],
            let mountEntry = entities.first(where: { $0["mount-point"] != nil }),
            let mountPath = mountEntry["mount-point"] as? String
        else {
            throw UpdateError.mountFailed
        }

        return URL(fileURLWithPath: mountPath)
    }

    private func findApp(in mountPoint: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: mountPoint,
            includingPropertiesForKeys: nil
        )
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appNotFoundInDMG
        }
        return appURL
    }

    private func replaceCurrentApp(with sourceApp: URL) throws {
        // Determine destination: where the current bundle lives
        let runningPath = Bundle.main.bundlePath
        let destURL = URL(fileURLWithPath: runningPath)
        let fm = FileManager.default

        // Remove old app
        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }
        // Copy new app
        try fm.copyItem(at: sourceApp, to: destURL)
    }

    private func detachDMG(mountPoint: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", mountPoint.path, "-force"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    private func relaunch() {
        // Use a shell to wait for the current process to exit, then reopen the app
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier

        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            open "\(bundlePath)"
            """

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        try? proc.run()

        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }

    private func setError(_ message: String) {
        DispatchQueue.main.async {
            self.installError = message
            self.isInstalling = false
            self.installStatus = ""
        }
    }
}

// MARK: - Errors

enum UpdateError: LocalizedError {
    case mountFailed
    case appNotFoundInDMG
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .mountFailed: return "Failed to mount the update disk image."
        case .appNotFoundInDMG: return "Could not find the app inside the downloaded update."
        case .copyFailed(let msg): return "Failed to install: \(msg)"
        }
    }
}
