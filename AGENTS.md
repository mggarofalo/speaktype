# AGENTS.md

Descended from [karansinghgit/speaktype](https://github.com/karansinghgit/speaktype), but **no longer in GitHub's fork network** (`isFork: false`, no parent). `main` here = upstream + this repo's patches; build from `main`.

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
- **Building on another machine requires recreating the cert.** Self-signed, CN `SpeakType Local Dev`, `codeSigning` EKU, imported to the login keychain and trusted for codeSign. Verify with `security find-identity -v -p codesigning` before building — until the cert is *trusted*, import alone leaves it listed as `0 valid identities` and the build fails at the CodeSign step. Working recipe (needs OpenSSL 3.x, e.g. `brew install openssl`; the system LibreSSL `/usr/bin/openssl` has no `-legacy`):

  ```bash
  P12PASS=some-nonempty-password
  openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
    -subj "/CN=SpeakType Local Dev" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning"
  openssl pkcs12 -export -legacy -macalg sha1 -out cert.p12 -inkey key.pem -in cert.pem -passout "pass:$P12PASS"
  security import cert.p12 -k ~/Library/Keychains/login.keychain-db -P "$P12PASS" -T /usr/bin/codesign
  security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
  rm -f key.pem cert.p12   # keychain holds the durable copy
  ```

  Both `-legacy` **and** `-macalg sha1` are required, and the PKCS12 password must be non-empty. Any of these missing makes `security import` fail with the misleading `MAC verification failed during PKCS12 import (wrong password?)` regardless of the actual password.

## Releases

`make release` is the whole process. A release is a version bump plus a git tag — the app is self-signed, so there is no notarized DMG and no GitHub Release object. The tag *is* the release.

```bash
make release                # patch bump (1.0.34 → 1.0.35)
make release BUMP=minor     # major / minor / patch
make release VERSION=1.2.3  # pin an exact version
make release DRY_RUN=1      # print the plan and the commit list, change nothing
```

Run it from a clean, synced `main`. The script refuses otherwise, and those refusals are the point — they are cheaper than unwinding a half-cut release.

What it does, and why the shape is load-bearing:

- **Gates on a Release build + unit tests before touching anything.** A tag that points at a broken build is worse than no tag. `--skip-checks` exists for emergencies; reach for it deliberately.
- **Branches, PRs, merges, and only then tags.** The `main` ruleset requires a pull request and has **no bypass actors**, so nothing can be pushed straight to `main` — a script that commits and tags before pushing will strand you with a local tag and a rejected push. Tagging last means a failure part-way through leaves no stray tag to clean up.
- **Tags the merge commit on `main`.** Tags therefore sit on `main` rather than on a branch that gets deleted seconds later. `v1.0.33` and `v1.0.34` disagree about this for historical reasons; everything from `v1.0.35` on is consistent.

If the merge step fails, the branch and bump commit are already pushed — merge the PR by hand, then `git tag vX.Y.Z && git push origin vX.Y.Z` from `main`. The script tells you this when it bails.

Version choice is a judgement call the script cannot make: it defaults to a patch bump, so pass `BUMP=minor` when a release adds user-facing capability rather than only repairing things.

## TCC / Permission Gotchas

- If the signature identity ever changes, the Accessibility toggle in System Settings still **shows enabled** but `AXIsProcessTrusted` returns false → the app falls back to clipboard-only output instead of pasting. Fix: `tccutil reset Accessibility com.mggarofalo.speaktype`, relaunch, re-grant.
- Models live in `~/Library/Application Support/SpeakType/huggingface/` (see `ModelStorage`). Upstream used `~/Documents/huggingface/`; `ModelStorage.migrateFromDocumentsIfNeeded()` moves a legacy install on launch. Don't reintroduce Documents paths — `~/Documents` is TCC-protected (terminal/agent processes can't read it, and files copied out of it carry a `com.apple.macl` xattr until stripped with `xattr -rc`).

## Transcription Engines

Two engines sit behind `TranscriptionEngine` / `TranscriptionEngineSelection` (`speaktype/Services/TranscriptionEngine.swift`), selectable in Settings → General and via the `transcriptionEngine` default (`whisperkit` | `whispercpp`):

- **whisper.cpp (Metal) — the default.** Measured ~10–15× faster than CoreML for the *same* large-v3-turbo model on Apple Silicon (sub-second vs ~5s on short clips); the CoreML framework overhead, not the silicon, was the bottleneck. `WhisperCppEngine` (actor) calls the vendored xcframework via the `WhisperCPP` package. GGML models live in `~/Library/Application Support/SpeakType/whispercpp/` (`WhisperCppModelStorage`), auto-downloaded per variant from HuggingFace `ggerganov/whisper.cpp`.
- **WhisperKit (CoreML) — kept selectable.** The original engine; CoreML models under `…/SpeakType/huggingface/` (`ModelStorage`).

Both share the model-picker UI via `ModelCatalogService` + the `ModelManager` facade (forwards to the active engine's `ModelDownloadService` / `GgmlModelDownloadService`). `AIModel.variant` is the canonical id across both; each model carries both a CoreML `variant` and a `ggmlFilename`.

`WhisperService` owns the observable UI state and routes load/transcribe to the active engine. Per-transcription RTF is logged to `AppLogger.transcription` with a `[compute=…]` tag for benchmarking.

### whisper.cpp API traps

Three of these have already shipped as user-visible breakage. They share a shape: the C API returns *success* while doing nothing useful.

- **Never set `params.detect_language`.** It does not mean "auto-detect" — it means *detect the language and stop*. `whisper_full` returns 0 having emitted zero segments, so the transcript is `""` and the UI says "No speech detected". Auto-detect is requested by leaving `params.language` nil, which detects **and then transcribes**. Pinned by `WhisperCppParamsTests`; the seam it tests (`WhisperCPPContext.makeParams`) exists for that purpose.
- **Free the context before the process exits.** ggml tears down its global Metal device in a static destructor during `exit()` and asserts `[rsets->data count] == 0` — "you haven't deallocated all Metal resources before exiting". The engine is a process-lifetime singleton, so nothing drops the context on its own; `AppDelegate.applicationShouldTerminate` does it explicitly. Remove that and ⌘Q aborts after any dictation. It uses `.terminateLater` rather than blocking on a semaphore because the target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and parking the main thread to await main-actor work deadlocks.
- **`whisper_full_default_params` defaults `language` to `"en"`, not nil.** Anything wanting auto-detect must overwrite it per call.

Model presence is engine-specific: ask `ModelManager.isDownloaded(variant:)`, never `ModelDownloadService.shared.downloadProgress` directly. That service only knows about CoreML models, so on the whisper.cpp path (the default) it reports every model as missing — which is exactly how a machine with a 1.6 GB model on disk ended up permanently showing "Model not downloaded".

English-only (`.en`) models ignore the language setting entirely — whisper.cpp emits English from them whatever is requested (verified: `auto`, `en`, and `fr` all returned English). `LanguagePreferences` resolves them to `"en"` and the UI disables the picker rather than letting the control silently do nothing.

## Compute Units (WhisperKit/CoreML engine only)

On the WhisperKit path, `WhisperService` routes the audio encoder and text decoder to `.cpuAndGPU`, not WhisperKit's default Neural Engine (override via the `debugComputeUnits` default). Measured on this hardware (large-v3_turbo, 16s clip, whisperkit-cli): ANE 3m08s vs GPU 56s load, identical output — ANE's CoreML specialization pass dominates load time. Don't "fix" this back to `ModelComputeOptions()` defaults. (Irrelevant to the whisper.cpp engine, which is the default and far faster regardless.)

## Upstream Relationship

The repo has since left the fork network, and the warning that used to sit here came true: upstream [#78](https://github.com/karansinghgit/speaktype/pull/78) merged first, but [#77](https://github.com/karansinghgit/speaktype/pull/77) is **closed and cannot be reopened**. Contributing upstream again means a fresh fork and a new PR — there is no link left to push a branch through.

Patches still get their own branch off `main`, which is what keeps that option open.

## Debugging

- `MiniRecorderView` writes a timestamped flow log to `/tmp/speaktype_debug.log` (hotkey → record → transcribe) — check it before instrumenting anything.
- Unified logging subsystem is `com.mggarofalo.speaktype` (`make logs` streams it).
- Recordings are kept at `~/Library/Application Support/SpeakType/Recordings/`. A transcription bug is usually reproducible straight from the offending `.wav` — far faster than trying to re-speak it, and it separates "bad audio" from "bad decode" in one step. Note the WAVs are `WAVE_FORMAT_EXTENSIBLE`, which Python's `wave` module refuses; parse the chunks manually or use `afinfo`.
- **`print()` from a test does not reach `xcodebuild`'s output.** A throwaway XCTest is the best way to drive the engine against a real file, but have it write results to a file — otherwise the test passes and you see nothing.
- **`make test` fails on a healthy tree.** The two `speaktypeUITests` cases need assistive access the test runner is not granted. Use `make test-unit` as the real gate; before blaming a change for a UI-test failure, confirm it fails identically on a stashed tree.
- Driving the app from a script mostly does not work — `osascript`/System Events lack assistive access here, so UI changes need a human to look at them. Say so plainly rather than implying a UI was verified.
