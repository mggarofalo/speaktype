# SpeakType

Offline voice dictation for macOS. Hold a hotkey, speak, release — the transcribed text is pasted at your cursor in whatever app has focus.

This is a maintained fork of [karansinghgit/speaktype](https://github.com/karansinghgit/speaktype), which deserves the credit for the original design and implementation. See [Changes in this fork](#changes-in-this-fork) for what differs.

## How it works

SpeakType runs [OpenAI Whisper](https://github.com/openai/whisper) models entirely on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Core ML). No audio or text ever leaves your Mac — there is no server component, no account, and no telemetry.

While you hold the hotkey, audio is captured with AVFoundation and written to disk. On release, the full recording is transcribed and the result is pasted into the frontmost app by synthesizing ⌘V (which is why the app needs Accessibility permission). Transcripts are also kept in a local history you can browse from the main window.

Models are downloaded once from Hugging Face (`argmaxinc/whisperkit-coreml`) and stored under `~/Library/Application Support/SpeakType/huggingface/`. Model sizes range from ~150 MB (`base`) to ~1.6 GB (`large-v3_turbo`). (Earlier versions stored models in `~/Documents/huggingface/`; the app migrates them automatically on launch.)

## Requirements

- macOS 14.0+ (the original upstream targets 13.0+)
- Apple Silicon strongly recommended (inference runs on the GPU/Neural Engine)
- 2 GB of free disk for the larger models

## Installation

Build from source:

```bash
git clone https://github.com/mggarofalo/speaktype.git
cd speaktype
make build && make run
```

On first launch:

1. Grant **Microphone** and **Accessibility** permissions when prompted (Accessibility is required for the paste-at-cursor behavior; without it, transcriptions land on the clipboard instead)
2. Download a model from **AI Models** in the main window
3. Pick your input device under **Settings → Audio**

Press and hold `fn` (default) to dictate. The hotkey and a toggle-instead-of-hold mode can be changed in Settings.

## Usage notes

- **Hold mode** (default): recording lasts exactly as long as you hold the hotkey
- **Toggle mode**: tap to start, tap to stop
- Press `Esc` while recording to cancel without pasting
- Say punctuation out loud: "comma", "period", "question mark"
- The first transcription after launch waits for the model to finish loading; subsequent dictations are near-instant (see below)

### Model warm-up

Loading a model takes time once per app launch — the model stays resident afterward. This fork routes inference to the GPU instead of the Neural Engine, which cut end-to-end load+transcribe time for `large-v3_turbo` from ~3 minutes to under a minute in testing (identical transcription output). Smaller models load in a few seconds. If you want the fastest possible readiness, `base` or `small` are nearly indistinguishable from `large` for clean English dictation.

## Changes in this fork

User-facing changes since the fork point (upstream v1.0.29):

**New features**

- Custom vocabulary — bias transcription toward names and jargon you specify
- Optional filler-word removal ("um", "uh", …) from transcriptions
- Optionally pause Music/Spotify while recording
- Menu-bar-only mode (hide the Dock icon)
- Launch on startup — optionally register SpeakType as a login item
- Modifier+key chords (e.g. ⌥⌘D) as dictation hotkeys, not just single keys
- The selected audio input device persists across restarts ([upstream PR #78](https://github.com/karansinghgit/speaktype/pull/78))

**Fixes**

- Hold-to-talk with the Fn hotkey no longer cancels recording instantly ([upstream PR #77](https://github.com/karansinghgit/speaktype/pull/77))
- Your clipboard contents are preserved across the dictation auto-paste
- Dictating while the app is hidden no longer restores the main window

**Performance**

- Inference runs on the GPU instead of the Neural Engine — ~3.4× faster model warm-up, identical output

**Behavior changes**

- All trial/license/Pro-upsell machinery removed — everything is free
- AI models are stored under `~/Library/Application Support/SpeakType/` instead of `~/Documents/` (existing models migrate automatically)
- The in-app updater points at this fork's releases

## Development

```bash
make build          # Debug build
make run            # Build and launch
make test           # Run tests
make lint           # SwiftLint
make clean          # Remove build artifacts
```

### Project structure

```
speaktype/
├── App/           # AppDelegate, hotkey monitoring
├── Views/         # SwiftUI interface (dashboard, settings, recorder overlay)
├── Models/        # Data models (hotkeys, AI models, history)
├── Services/      # Audio capture, WhisperKit wrapper, model downloads, history
├── Controllers/   # Recorder panel window management
└── Resources/     # Assets, entitlements
```

### Tech stack

- Swift / SwiftUI + AppKit
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device Whisper inference (Core ML)
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — global hotkeys
- AVFoundation — audio capture

## License

MIT — see [LICENSE](LICENSE).

## Credits

- [karansinghgit/speaktype](https://github.com/karansinghgit/speaktype) — the original project this fork builds on
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax
- [OpenAI Whisper](https://github.com/openai/whisper)
