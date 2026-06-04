import AppKit
import Foundation

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

    private init() {}

    private struct Player {
        let appName: String  // AppleScript application name
        let bundleID: String
    }

    private static let players = [
        Player(appName: "Music", bundleID: "com.apple.Music"),
        Player(appName: "Spotify", bundleID: "com.spotify.client"),
    ]

    /// Players we paused for the current recording — only these are resumed.
    private var pausedPlayers: [Player] = []

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
            var paused: [Player] = []

            for player in Self.players where self.isRunning(player) {
                let state = self.runAppleScript(
                    "tell application \"\(player.appName)\" to return player state as string"
                )
                if state?.lowercased() == "playing" {
                    _ = self.runAppleScript(
                        "tell application \"\(player.appName)\" to pause")
                    paused.append(player)
                    print("⏸️ Paused \(player.appName) for recording")
                }
            }

            DispatchQueue.main.async { self.pausedPlayers = paused }
        }
    }

    /// Resume only the players this service paused.
    func resumeAfterRecording() {
        let players = pausedPlayers
        pausedPlayers = []
        guard !players.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for player in players where self.isRunning(player) {
                _ = self.runAppleScript("tell application \"\(player.appName)\" to play")
                print("▶️ Resumed \(player.appName) after recording")
            }
        }
    }

    private func isRunning(_ player: Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
    }

    private func runAppleScript(_ source: String) -> String? {
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
