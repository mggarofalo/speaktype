import AppKit
import Foundation

/// Side-effect boundary for media control: running an Apple Event script and
/// checking whether a player app is running. The production conformance wraps
/// NSAppleScript/NSRunningApplication; tests substitute a recording fake.
protocol MediaScriptRunning {
    /// True when an app with `bundleID` is currently running.
    func isRunning(bundleID: String) -> Bool
    /// Execute an AppleScript `source`, returning its string result (nil on error).
    func runAppleScript(_ source: String) -> String?
}

/// Pauses Music/Spotify while a recording is in progress and resumes whatever
/// was playing afterwards (upstream issue #63). Opt-in via the
/// "pauseMediaDuringRecording" setting.
///
/// Uses Apple Events (the app already holds the automation entitlement);
/// macOS shows a one-time "SpeakType wants to control Music/Spotify" consent
/// prompt per player. Scripts only run when the player app is running, so no
/// player gets launched just to be asked whether it is playing.
class MediaPlaybackService {
    static let shared = MediaPlaybackService()

    private let scriptRunner: MediaScriptRunning

    init(scriptRunner: MediaScriptRunning = SystemMediaScriptRunner()) {
        self.scriptRunner = scriptRunner
    }

    // The project defaults to MainActor isolation, which would give this type a
    // main-actor-isolated deinit. There is no main-actor state to tear down, and
    // the back-deployed main-actor deinit path crashes when a non-`shared`
    // instance is released under test. A nonisolated deinit avoids that hop.
    nonisolated deinit {}

    struct Player: Equatable {
        let appName: String  // AppleScript application name
        let bundleID: String
    }

    private static let players = [
        Player(appName: "Music", bundleID: "com.apple.Music"),
        Player(appName: "Spotify", bundleID: "com.spotify.client"),
    ]

    /// Players we paused for the current recording — only these are resumed.
    private(set) var pausedPlayers: [Player] = []

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "pauseMediaDuringRecording")
    }

    /// Pause any running player that is currently playing. Synchronous Apple
    /// Events are dispatched off the main thread; player state is small and
    /// the scripts return quickly.
    func pauseForRecording() {
        guard isEnabled else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let paused = self.pauseRunningPlayers()
            DispatchQueue.main.async { self.pausedPlayers = paused }
        }
    }

    /// Resume only the players this service paused.
    func resumeAfterRecording() {
        let players = takePausedPlayers()
        guard !players.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.resumePlayers(players)
        }
    }

    /// Read and clear the paused-player set in one step, so a second resume
    /// finds nothing to do. Synchronous and side-effect-free beyond the state
    /// reset (internal so tests can verify the clearing without the async hop).
    func takePausedPlayers() -> [Player] {
        let players = pausedPlayers
        pausedPlayers = []
        return players
    }

    /// Pause every running, currently-playing player and return the set paused.
    /// Synchronous decision logic, isolated from the dispatch hop so it is
    /// exercisable directly (internal so tests can drive it without the async hop).
    func pauseRunningPlayers() -> [Player] {
        var paused: [Player] = []
        for player in Self.players where scriptRunner.isRunning(bundleID: player.bundleID) {
            let state = scriptRunner.runAppleScript(
                "tell application \"\(player.appName)\" to return player state as string"
            )
            if state?.lowercased() == "playing" {
                _ = scriptRunner.runAppleScript(
                    "tell application \"\(player.appName)\" to pause")
                paused.append(player)
                print("⏸️ Paused \(player.appName) for recording")
            }
        }
        return paused
    }

    /// Resume the given players that are still running. Synchronous decision
    /// logic, isolated from the dispatch hop so it is exercisable directly
    /// (internal so tests can drive it without the async hop).
    func resumePlayers(_ players: [Player]) {
        for player in players where scriptRunner.isRunning(bundleID: player.bundleID) {
            _ = scriptRunner.runAppleScript("tell application \"\(player.appName)\" to play")
            print("▶️ Resumed \(player.appName) after recording")
        }
    }

    #if DEBUG
    /// Seed the paused-player set so resume-side logic can be driven directly
    /// in tests, bypassing the async hop in `pauseForRecording`.
    func setPausedPlayersForTesting(_ players: [Player]) {
        pausedPlayers = players
    }
    #endif
}

/// Production conformance: the original NSAppleScript/NSRunningApplication code.
struct SystemMediaScriptRunner: MediaScriptRunning {
    func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            print("⚠️ Media AppleScript error: \(error)")
            return nil
        }
        return result.stringValue
    }
}
