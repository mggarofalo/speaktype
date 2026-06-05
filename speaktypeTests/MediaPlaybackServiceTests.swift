import XCTest
@testable import speaktype

@MainActor
final class MediaPlaybackServiceTests: XCTestCase {

    private static let settingKey = "pauseMediaDuringRecording"

    // Bundle IDs the service knows about (see MediaPlaybackService.players).
    private let musicBundleID = "com.apple.Music"
    private let spotifyBundleID = "com.spotify.client"

    /// Records every invocation and returns scripted player states.
    ///
    /// `running` is the set of bundle IDs treated as running apps.
    /// `playerStates` maps an app name to the string the "player state" query
    /// returns. A missing entry simulates a failed query (NSAppleScript returns
    /// nil on error); a present-but-unrecognized value simulates garbage output.
    private final class MockScriptRunner: MediaScriptRunning {
        var running: Set<String>
        var playerStates: [String: String]

        private(set) var isRunningQueries: [String] = []
        private(set) var scripts: [String] = []

        init(running: Set<String>, playerStates: [String: String]) {
            self.running = running
            self.playerStates = playerStates
        }

        func isRunning(bundleID: String) -> Bool {
            isRunningQueries.append(bundleID)
            return running.contains(bundleID)
        }

        func runAppleScript(_ source: String) -> String? {
            scripts.append(source)
            // Resolve a "player state" query by matching the app name in the source.
            for (appName, state) in playerStates where source.contains("\"\(appName)\"") {
                if source.contains("player state") {
                    return state
                }
            }
            return nil
        }

        /// Scripts that paused a player.
        var pauseScripts: [String] { scripts.filter { $0.hasSuffix("to pause") } }
        /// Scripts that resumed (played) a player.
        var playScripts: [String] { scripts.filter { $0.hasSuffix("to play") } }
    }

    private func player(_ appName: String, _ bundleID: String) -> MediaPlaybackService.Player {
        MediaPlaybackService.Player(appName: appName, bundleID: bundleID)
    }

    // MARK: - Setting gate (UserDefaults — save/restore per project convention)

    private var savedSetting: Any?

    override func setUp() {
        super.setUp()
        savedSetting = UserDefaults.standard.object(forKey: Self.settingKey)
    }

    override func tearDown() {
        if let savedSetting {
            UserDefaults.standard.set(savedSetting, forKey: Self.settingKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.settingKey)
        }
        super.tearDown()
    }

    func testPauseForRecordingDoesNothingWhenSettingDisabled() {
        UserDefaults.standard.set(false, forKey: Self.settingKey)
        let runner = MockScriptRunner(
            running: [musicBundleID, spotifyBundleID],
            playerStates: ["Music": "playing", "Spotify": "playing"]
        )
        let service = MediaPlaybackService(scriptRunner: runner)

        // The setting gate short-circuits synchronously, before any dispatch.
        service.pauseForRecording()

        XCTAssertTrue(runner.scripts.isEmpty,
                      "No AppleScript should run when the setting is off")
        XCTAssertTrue(runner.isRunningQueries.isEmpty,
                      "Running checks should not even be attempted when off")
    }

    // MARK: - pauseRunningPlayers decision logic

    func testPauseRunningPlayersPausesOnlyRunningAndPlayingPlayers() {
        // Music: running + playing -> pause. Spotify: running but paused -> skip.
        // A third, not-running player is never scripted.
        let runner = MockScriptRunner(
            running: [musicBundleID, spotifyBundleID],
            playerStates: ["Music": "playing", "Spotify": "paused"]
        )
        let service = MediaPlaybackService(scriptRunner: runner)

        let paused = service.pauseRunningPlayers()

        XCTAssertEqual(paused.map(\.bundleID), [musicBundleID],
                       "Only the running-and-playing player is paused")
        XCTAssertEqual(runner.pauseScripts,
                       ["tell application \"Music\" to pause"])
        XCTAssertTrue(runner.playScripts.isEmpty)
    }

    func testPauseRunningPlayersSkipsNotRunningPlayersWithoutScripting() {
        // Spotify not running: must not be state-queried or paused, even though
        // its scripted state would say "playing".
        let runner = MockScriptRunner(
            running: [musicBundleID],
            playerStates: ["Music": "playing", "Spotify": "playing"]
        )
        let service = MediaPlaybackService(scriptRunner: runner)

        let paused = service.pauseRunningPlayers()

        XCTAssertEqual(paused.map(\.bundleID), [musicBundleID])
        // No script for Spotify at all — no wasted Apple Events on a dead app.
        XCTAssertFalse(runner.scripts.contains { $0.contains("\"Spotify\"") },
                       "Not-running players must never be scripted")
    }

    func testPauseRunningPlayersTreatsFailedStateQueryAsNotPlaying() {
        // Music's state query is omitted -> runAppleScript returns nil (the
        // failure NSAppleScript yields on error). Spotify returns garbage.
        // Neither should be paused.
        let runner = MockScriptRunner(
            running: [musicBundleID, spotifyBundleID],
            playerStates: ["Spotify": "not-a-real-state"]
        )
        let service = MediaPlaybackService(scriptRunner: runner)

        let paused = service.pauseRunningPlayers()

        XCTAssertTrue(paused.isEmpty,
                      "A failed or garbage state query is treated as not playing")
        XCTAssertTrue(runner.pauseScripts.isEmpty, "No pause attempted")
    }

    func testPauseRunningPlayersMatchesPlayingStateCaseInsensitively() {
        // The service lowercases the state before comparing.
        let runner = MockScriptRunner(
            running: [musicBundleID],
            playerStates: ["Music": "Playing"]
        )
        let service = MediaPlaybackService(scriptRunner: runner)

        let paused = service.pauseRunningPlayers()

        XCTAssertEqual(paused.map(\.bundleID), [musicBundleID])
    }

    // MARK: - resume decision logic + paused-state bookkeeping

    func testResumePlaysOnlyPlayersWePausedAndClearsState() {
        let runner = MockScriptRunner(
            running: [musicBundleID, spotifyBundleID],
            playerStates: [:]
        )
        let service = MediaPlaybackService(scriptRunner: runner)

        // Pretend we previously paused only Music.
        service.setPausedPlayersForTesting([player("Music", musicBundleID)])

        let toResume = service.takePausedPlayers()
        XCTAssertEqual(toResume.map(\.bundleID), [musicBundleID])
        XCTAssertTrue(service.pausedPlayers.isEmpty,
                      "Taking the set must clear it")

        service.resumePlayers(toResume)

        XCTAssertEqual(runner.playScripts,
                       ["tell application \"Music\" to play"],
                       "Only the player we paused is resumed — Spotify is left alone")
    }

    func testSecondTakePausedPlayersIsANoOp() {
        let runner = MockScriptRunner(running: [], playerStates: [:])
        let service = MediaPlaybackService(scriptRunner: runner)
        service.setPausedPlayersForTesting([player("Music", musicBundleID)])

        _ = service.takePausedPlayers()
        let second = service.takePausedPlayers()

        XCTAssertTrue(second.isEmpty,
                      "After resuming, a second resume finds nothing to do")
    }

    func testResumeSkipsPlayersThatAreNoLongerRunning() {
        // We paused Music, but it has since quit — do not script a dead app.
        let runner = MockScriptRunner(running: [], playerStates: [:])
        let service = MediaPlaybackService(scriptRunner: runner)

        service.resumePlayers([player("Music", musicBundleID)])

        XCTAssertTrue(runner.playScripts.isEmpty,
                      "A player that is no longer running is not resumed")
        XCTAssertEqual(runner.isRunningQueries, [musicBundleID])
    }
}
