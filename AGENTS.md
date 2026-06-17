# AGENTS.md

Fork of [karansinghgit/speaktype](https://github.com/karansinghgit/speaktype). `main` here = upstream + this fork's patches; build from `main`.

## Build, Sign & Install

The project signs with `CODE_SIGN_IDENTITY = "SpeakType Local Dev"` — a self-signed cert in the login keychain (created 2026-06-04, 10-year validity). Plain builds just work:

```bash
xcodebuild -project speaktype.xcodeproj -scheme speaktype -configuration Release build
```

**Build prerequisite:** the whisper.cpp engine links a vendored `whisper.xcframework` (local SwiftPM package `Vendor/WhisperCPP`). The 48MB binary is **gitignored** — on a fresh checkout run `scripts/fetch-whisper-xcframework.sh` once before building, or the package fails to resolve. `scripts/build-beta.sh` runs it automatically.

Install = quit the app, `ditto` the built .app over `/Applications/speaktype.app`, relaunch. No re-signing step.

Signing constraints (load-bearing — do not "modernize" these):

- **Keep the stable identity.** TCC grants (Accessibility, Microphone) are tied to the signing identity; ad-hoc (`-`) signing changes the CDHash every rebuild and silently invalidates them.
- **Keep `ENABLE_HARDENED_RUNTIME = NO`.** A self-signed identity has no Team ID, so hardened-runtime library validation makes dyld refuse the embedded `WhisperKit.framework` (`Library not loaded` crash at launch).
- Building on another machine requires recreating the cert: self-signed code-signing cert named "SpeakType Local Dev", imported to login keychain, trusted for codeSign. macOS rejects OpenSSL 3.x PKCS12 defaults — export with `-legacy`.

## TCC / Permission Gotchas

- If the signature identity ever changes, the Accessibility toggle in System Settings still **shows enabled** but `AXIsProcessTrusted` returns false → the app falls back to clipboard-only output instead of pasting. Fix: `tccutil reset Accessibility com.mggarofalo.speaktype`, relaunch, re-grant.
- Models live in `~/Library/Application Support/SpeakType/huggingface/` (see `ModelStorage`). Upstream used `~/Documents/huggingface/`; `ModelStorage.migrateFromDocumentsIfNeeded()` moves a legacy install on launch. Don't reintroduce Documents paths — `~/Documents` is TCC-protected (terminal/agent processes can't read it, and files copied out of it carry a `com.apple.macl` xattr until stripped with `xattr -rc`).

## Transcription Engines

Two engines sit behind `TranscriptionEngine` / `TranscriptionEngineSelection` (`speaktype/Services/TranscriptionEngine.swift`), selectable in Settings → General and via the `transcriptionEngine` default (`whisperkit` | `whispercpp`):

- **whisper.cpp (Metal) — the default.** Measured ~10–15× faster than CoreML for the *same* large-v3-turbo model on Apple Silicon (sub-second vs ~5s on short clips); the CoreML framework overhead, not the silicon, was the bottleneck. `WhisperCppEngine` (actor) calls the vendored xcframework via the `WhisperCPP` package. GGML models live in `~/Library/Application Support/SpeakType/whispercpp/` (`WhisperCppModelStorage`), auto-downloaded per variant from HuggingFace `ggerganov/whisper.cpp`.
- **WhisperKit (CoreML) — kept selectable.** The original engine; CoreML models under `…/SpeakType/huggingface/` (`ModelStorage`).

Both share the model-picker UI via `ModelCatalogService` + the `ModelManager` facade (forwards to the active engine's `ModelDownloadService` / `GgmlModelDownloadService`). `AIModel.variant` is the canonical id across both; each model carries both a CoreML `variant` and a `ggmlFilename`.

`WhisperService` owns the observable UI state and routes load/transcribe to the active engine. Per-transcription RTF is logged to `AppLogger.transcription` with a `[compute=…]` tag for benchmarking.

## Compute Units (WhisperKit/CoreML engine only)

On the WhisperKit path, `WhisperService` routes the audio encoder and text decoder to `.cpuAndGPU`, not WhisperKit's default Neural Engine (override via the `debugComputeUnits` default). Measured on this hardware (large-v3_turbo, 16s clip, whisperkit-cli): ANE 3m08s vs GPU 56s load, identical output — ANE's CoreML specialization pass dominates load time. Don't "fix" this back to `ModelComputeOptions()` defaults. (Irrelevant to the whisper.cpp engine, which is the default and far faster regardless.)

## Fork / Upstream Relationship

- Keep the GitHub fork link: open upstream PRs ([#77](https://github.com/karansinghgit/speaktype/pull/77), [#78](https://github.com/karansinghgit/speaktype/pull/78)) close permanently if the repo leaves the fork network.
- Patches intended for upstream get their own branch off `main` so they can be PR'd independently.

## Debugging

- `MiniRecorderView` writes a timestamped flow log to `/tmp/speaktype_debug.log` (hotkey → record → transcribe) — check it before instrumenting anything.
- Unified logging subsystem is `com.mggarofalo.speaktype` (`make logs` streams it).
