import Combine
import KeyboardShortcuts
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var miniRecorderController: MiniRecorderWindowController?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var hotkeyEventTap: CFMachPort?
    private var hotkeyEventTapSource: CFRunLoopSource?
    var isHotkeyPressed = false
    private var cancellables = Set<AnyCancellable>()
    private var lastHandledHotkeyTimestamp: TimeInterval = 0
    private var lastHandledHotkeyPressedState = false
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.applyDockIconPolicy()

        miniRecorderController = MiniRecorderWindowController()

        // Setup dynamic hotkey monitoring based on user selection
        setupHotkeyMonitoring()

        checkForUpdatesOnLaunch()

        UpdateService.shared.showUpdateWindowPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.showUpdateWindow()
            }
            .store(in: &cancellables)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Dock Icon

    /// Apply the user's Dock icon preference. `.accessory` hides the Dock icon
    /// (menu-bar-only operation); `.regular` restores it. Called at launch and
    /// whenever Settings toggles the preference. When hiding, the menu bar
    /// icon is forced on so the app always stays reachable.
    static func applyDockIconPolicy() {
        let hide = UserDefaults.standard.bool(forKey: "hideDockIcon")
        if hide {
            UserDefaults.standard.set(true, forKey: "showMenuBarIcon")
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    // MARK: - Emoji Picker Suppression

    /// F19 — posted by suppressEmojiPicker(). The synthetic event inherits the live
    /// modifier state (including the held Fn flag), so the modifier-combo cancel
    /// guard must ignore this key code or it cancels the recording it just started.
    private static let emojiSuppressionKeyCode: CGKeyCode = 0x50  // F19 (80)

    private func suppressEmojiPicker() {
        // A robust way to suppress the emoji picker is to post a harmless keydown/keyup
        // with the F19 key (a non-modifier key), which immediately breaks the Globe key's double-tap
        // or press-and-release listener without causing a spurious flagsChanged event.
        let dummyKeyCode = Self.emojiSuppressionKeyCode
        let eventSource = CGEventSource(stateID: .hidSystemState)

        if let keyDown = CGEvent(
            keyboardEventSource: eventSource, virtualKey: dummyKeyCode, keyDown: true)
        {
            keyDown.post(tap: .cghidEventTap)
        }

        if let keyUp = CGEvent(
            keyboardEventSource: eventSource, virtualKey: dummyKeyCode, keyDown: false)
        {
            keyUp.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Hotkey Monitoring

    private func setupHotkeyMonitoring() {
        setupSuppressingHotkeyEventTap()

        // Add global monitor for hotkey events
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handleHotkeyEvent(event)
        }

        // Add local monitor for hotkey events (same logic)
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handleHotkeyEvent(event)
            return event
        }

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handleModifierComboEvent(event)
        }

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handleModifierComboEvent(event)
            return event
        }

        setupChordHotkeyListeners()
    }

    /// Chord hotkeys (e.g. ⌃V) are handled by the KeyboardShortcuts package:
    /// Carbon registration both delivers keyDown/keyUp and consumes the chord
    /// so it never reaches the focused app. Only enabled while the selected
    /// hotkey is `.chord`, otherwise the recorded chord would be swallowed
    /// system-wide for no reason.
    private func setupChordHotkeyListeners() {
        KeyboardShortcuts.onKeyDown(for: .dictationChord) { [weak self] in
            guard let self, self.getSelectedHotkey() == .chord else { return }
            self.handleHotkeyStateChange(isPressed: true)
        }
        KeyboardShortcuts.onKeyUp(for: .dictationChord) { [weak self] in
            guard let self, self.getSelectedHotkey() == .chord else { return }
            self.handleHotkeyStateChange(isPressed: false)
        }
        syncChordHotkeyEnabled()
    }

    /// Keep the Carbon registration in sync with the selected hotkey. Called at
    /// launch and whenever Settings changes the hotkey selection.
    static func syncChordHotkeyEnabled() {
        let isChord = UserDefaults.standard.string(forKey: "selectedHotkey") == HotkeyOption.chord.rawValue
        if isChord {
            KeyboardShortcuts.enable(.dictationChord)
        } else {
            KeyboardShortcuts.disable(.dictationChord)
        }
    }

    private func syncChordHotkeyEnabled() {
        Self.syncChordHotkeyEnabled()
    }

    private func setupSuppressingHotkeyEventTap() {
        guard hotkeyEventTap == nil else { return }

        let eventMask = (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }

            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            return appDelegate.handleHotkeyEventTap(type: type, event: event)
        }

        guard
            let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(eventMask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            print("Failed to create suppressing hotkey event tap")
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        hotkeyEventTap = eventTap
        hotkeyEventTapSource = runLoopSource
    }

    private func handleHotkeyEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let hotkeyEventTap {
                CGEvent.tapEnable(tap: hotkeyEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let currentHotkey = getSelectedHotkey()
        guard currentHotkey == .fn else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == currentHotkey.keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let isPressed = event.flags.contains(.maskSecondaryFn)
        DispatchQueue.main.async { [weak self] in
            self?.handleHotkeyStateChange(isPressed: isPressed)
        }

        // Suppress the Fn flagsChanged event so terminal apps do not receive raw CSI sequences.
        return nil
    }

    private func handleHotkeyEvent(_ event: NSEvent) {
        let currentHotkey = getSelectedHotkey()
        guard currentHotkey != .chord else { return }  // Chords are handled by KeyboardShortcuts
        guard event.keyCode == currentHotkey.keyCode else { return }

        let isPressed = event.modifierFlags.contains(currentHotkey.modifierFlag)
        handleHotkeyStateChange(isPressed: isPressed)
    }

    private func handleHotkeyStateChange(isPressed: Bool) {
        guard !isDuplicateHotkeyEvent(isPressed: isPressed) else { return }

        let currentHotkey = getSelectedHotkey()
        if isPressed && !isHotkeyPressed {
            isHotkeyPressed = true

            if currentHotkey == .fn {
                suppressEmojiPicker()
            }

            let recordingMode = UserDefaults.standard.integer(forKey: "recordingMode")
            if recordingMode == 1 {
                if AudioRecordingService.shared.isRecording {
                    miniRecorderController?.stopRecording()
                } else {
                    miniRecorderController?.startRecording()
                }
            } else {
                miniRecorderController?.startRecording()
            }
        } else if !isPressed && isHotkeyPressed {
            isHotkeyPressed = false

            let recordingMode = UserDefaults.standard.integer(forKey: "recordingMode")
            if recordingMode == 0 {
                miniRecorderController?.stopRecording()
            }
        }
    }

    private func handleModifierComboEvent(_ event: NSEvent) {
        guard isHotkeyPressed else { return }
        // Combo-cancel exists for modifier-only hotkeys (#43): the user pressed
        // e.g. ⌘C while their ⌘ hotkey was recording. A chord hotkey already
        // includes a non-modifier key, so this heuristic does not apply.
        guard getSelectedHotkey() != .chord else { return }
        guard UserDefaults.standard.integer(forKey: "recordingMode") == 0 else { return }
        guard !event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return }
        guard event.keyCode != getSelectedHotkey().keyCode else { return }
        // Ignore the synthetic F19 posted by suppressEmojiPicker() — it carries the
        // held Fn flag and would otherwise cancel the recording immediately.
        guard event.keyCode != Self.emojiSuppressionKeyCode else { return }

        isHotkeyPressed = false
        miniRecorderController?.cancelRecording()
    }

    private func isDuplicateHotkeyEvent(isPressed: Bool) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let isDuplicate =
            abs(now - lastHandledHotkeyTimestamp) < 0.05
            && lastHandledHotkeyPressedState == isPressed

        lastHandledHotkeyTimestamp = now
        lastHandledHotkeyPressedState = isPressed
        return isDuplicate
    }

    private func getSelectedHotkey() -> HotkeyOption {
        // Migration: Check if old useFnKey setting exists
        if UserDefaults.standard.object(forKey: "useFnKey") != nil {
            let useFnKey = UserDefaults.standard.bool(forKey: "useFnKey")
            if useFnKey {
                UserDefaults.standard.set(HotkeyOption.fn.rawValue, forKey: "selectedHotkey")
                UserDefaults.standard.removeObject(forKey: "useFnKey")
                return .fn
            }
        }

        if let rawValue = UserDefaults.standard.string(forKey: "selectedHotkey"),
            let option = HotkeyOption(rawValue: rawValue)
        {
            return option
        }

        return .fn
    }

    // MARK: - Update Checking

    private func checkForUpdatesOnLaunch() {
        let updateService = UpdateService.shared
        let autoUpdate = UserDefaults.standard.bool(forKey: "autoUpdate")
        guard autoUpdate && updateService.shouldCheckForUpdates() else { return }

        Task {
            await updateService.checkForUpdates(silent: true)
            if updateService.availableUpdate != nil && updateService.shouldShowReminder() {
                await MainActor.run { self.showUpdateWindow() }
            }
        }
    }

    private func showUpdateWindow() {
        guard let update = UpdateService.shared.availableUpdate else { return }

        let updateSheetView = UpdateSheet(update: update)
        let hostingController = NSHostingController(rootView: updateSheetView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Software Update"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.isMovableByWindowBackground = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
