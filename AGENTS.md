# AGENTS.md

Fork of [karansinghgit/speaktype](https://github.com/karansinghgit/speaktype). `main` here = upstream + this fork's patches; build from `main`.

## Build, Sign & Install

The project signs with `CODE_SIGN_IDENTITY = "SpeakType Local Dev"` — a self-signed cert in the login keychain (created 2026-06-04, 10-year validity). Plain builds just work:

```bash
xcodebuild -project speaktype.xcodeproj -scheme speaktype -configuration Release build
```

Install = quit the app, `ditto` the built .app over `/Applications/speaktype.app`, relaunch. No re-signing step.

Signing constraints (load-bearing — do not "modernize" these):

- **Keep the stable identity.** TCC grants (Accessibility, Microphone) are tied to the signing identity; ad-hoc (`-`) signing changes the CDHash every rebuild and silently invalidates them.
- **Keep `ENABLE_HARDENED_RUNTIME = NO`.** A self-signed identity has no Team ID, so hardened-runtime library validation makes dyld refuse the embedded `WhisperKit.framework` (`Library not loaded` crash at launch).
- Building on another machine requires recreating the cert: self-signed code-signing cert named "SpeakType Local Dev", imported to login keychain, trusted for codeSign. macOS rejects OpenSSL 3.x PKCS12 defaults — export with `-legacy`.

## TCC / Permission Gotchas

- If the signature identity ever changes, the Accessibility toggle in System Settings still **shows enabled** but `AXIsProcessTrusted` returns false → the app falls back to clipboard-only output instead of pasting. Fix: `tccutil reset Accessibility com.2048labs.speaktype`, relaunch, re-grant.
- Models live in `~/Documents/huggingface/` (non-sandboxed documents dir). `~/Documents` is TCC-protected — terminal/agent processes typically cannot read it, and files copied out of it carry a `com.apple.macl` xattr that keeps blocking access until stripped (`xattr -rc`).

## Compute Units (deliberate divergence from upstream)

`WhisperService` routes the audio encoder and text decoder to `.cpuAndGPU`, not WhisperKit's default Neural Engine. Measured on this hardware (large-v3_turbo, 16s clip, whisperkit-cli): ANE 3m08s vs GPU 56s end-to-end, identical output — ANE's CoreML specialization pass dominates load time. Don't "fix" this back to `ModelComputeOptions()` defaults.

## Fork / Upstream Relationship

- Keep the GitHub fork link: open upstream PRs ([#77](https://github.com/karansinghgit/speaktype/pull/77), [#78](https://github.com/karansinghgit/speaktype/pull/78)) close permanently if the repo leaves the fork network.
- Patches intended for upstream get their own branch off `main` so they can be PR'd independently.

## Debugging

- `MiniRecorderView` writes a timestamped flow log to `/tmp/speaktype_debug.log` (hotkey → record → transcribe) — check it before instrumenting anything.
- Unified logging subsystem is `com.2048labs.speaktype` (`make logs` streams it).
